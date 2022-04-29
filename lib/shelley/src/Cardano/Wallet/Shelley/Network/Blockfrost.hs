{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

{-# OPTIONS_GHC -Wno-unused-imports #-}
{-# LANGUAGE UndecidableInstances #-}

-- |
-- Copyright: © 2020 IOHK
-- License: Apache-2.0
--
-- Network Layer implementation that uses Blockfrost API
--
module Cardano.Wallet.Shelley.Network.Blockfrost
    ( withNetworkLayer
    , Log

    -- * Internal
    , getPoolPerformanceEstimate
    , eraByEpoch
    , fetchBlock
    , fetchTransaction
    , newClientConfig
    , BFM (..)
    , runBFM
    , BlockfrostError (..)
    ) where

import Prelude

import qualified Blockfrost.Client as BF
import qualified Cardano.Api.Shelley as Node
import qualified Cardano.Binary as CBOR
import qualified Cardano.Ledger.Shelley.Metadata as Shelley
import qualified Cardano.Wallet.Network.Light as LN
import qualified Data.Aeson as Json
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import qualified Data.Text as T
import qualified Data.Vector as Vec
import qualified Ouroboros.Consensus.Cardano.Block as OC
import qualified Ouroboros.Consensus.HardFork.History.Qry as HF

import Cardano.Api
    ( AnyCardanoEra (..)
    , AsType (AsTxMetadata)
    , CardanoEra (AllegraEra, AlonzoEra, ByronEra, MaryEra, ShelleyEra)
    , CardanoEraStyle (LegacyByronEra, ShelleyBasedEra)
    , ExecutionUnitPrices (priceExecutionMemory, priceExecutionSteps)
    , ExecutionUnits (executionMemory, executionSteps)
    , NetworkId (..)
    , NetworkMagic (..)
    , TxMetadata (TxMetadata)
    , TxMetadataValue (..)
    , cardanoEraStyle
    , makeTransactionMetadata
    , proxyToAsType
    )
import Cardano.Api.Shelley
    ( fromShelleyMetadata )
import Cardano.Binary
    ( fromCBOR )
import Cardano.BM.Data.Severity
    ( Severity (..) )
import Cardano.BM.Tracer
    ( Tracer )
import Cardano.BM.Tracing
    ( HasSeverityAnnotation (getSeverityAnnotation) )
import Cardano.Pool.Rank
    ( RewardParams (..) )
import Cardano.Pool.Rank.Likelihood
    ( BlockProduction (..), PerformanceEstimate (..), estimatePoolPerformance )
import Cardano.Wallet.Api.Types
    ( decodeAddress, decodeStakeAddress, encodeStakeAddress )
import Cardano.Wallet.Logging
    ( BracketLog, bracketTracer )
import Cardano.Wallet.Network
    ( ChainFollower, NetworkLayer (..) )
import Cardano.Wallet.Network.Light
    ( LightBlocks, LightSyncSource (..) )
import Cardano.Wallet.Primitive.Slotting
    ( PastHorizonException
    , TimeInterpreter
    , TimeInterpreterLog
    , mkTimeInterpreter
    )
import Cardano.Wallet.Primitive.Types
    ( Block (..)
    , BlockHeader (..)
    , ChainPoint (..)
    , DecentralizationLevel (..)
    , DelegationCertificate (..)
    , EpochNo (..)
    , ExecutionUnitPrices (..)
    , ExecutionUnits (..)
    , FeePolicy (LinearFee)
    , GenesisParameters (..)
    , LinearFunction (..)
    , MinimumUTxOValue (..)
    , NetworkParameters (..)
    , ProtocolParameters (..)
    , SlotNo (..)
    , SlottingParameters (..)
    , StartTime
    , TokenBundleMaxSize (..)
    , TxParameters (..)
    , decodePoolIdBech32
    , emptyEraInfo
    , executionMemory
    , executionSteps
    , genesisParameters
    , getGenesisBlockDate
    , header
    , slottingParameters
    , stabilityWindowByron
    , stabilityWindowShelley
    )
import Cardano.Wallet.Primitive.Types.Address
    ( Address )
import Cardano.Wallet.Primitive.Types.Coin
    ( Coin (Coin, unCoin) )
import Cardano.Wallet.Primitive.Types.Hash
    ( Hash )
import Cardano.Wallet.Primitive.Types.RewardAccount
    ( RewardAccount )
import Cardano.Wallet.Primitive.Types.TokenBundle
    ( TokenBundle (..) )
import Cardano.Wallet.Primitive.Types.Tx
    ( Tx (..)
    , TxIn (..)
    , TxOut (..)
    , TxScriptValidity (TxScriptInvalid, TxScriptValid)
    , TxSize (..)
    , txId
    )
import Cardano.Wallet.Shelley.Network.Discriminant
    ( SomeNetworkDiscriminant (..), networkDiscriminantToId )
import Control.Concurrent
    ( threadDelay )
import Control.Concurrent.Async.Lifted
    ( concurrently, mapConcurrently )
import Control.Monad
    ( forever, join, (<=<), (>=>) )
import Control.Monad.Base
    ( MonadBase )
import Control.Monad.Error.Class
    ( MonadError, liftEither, throwError )
import Control.Monad.IO.Class
    ( MonadIO (liftIO) )
import Control.Monad.Reader
    ( MonadReader, ReaderT (runReaderT), ask, asks )
import Control.Monad.Trans.Control
    ( MonadBaseControl )
import Control.Monad.Trans.Except
    ( ExceptT (..), runExceptT, withExceptT )
import Data.Align
    ( align )
import Data.Bifunctor
    ( bimap, first )
import Data.Bitraversable
    ( bitraverse )
import Data.Bits
    ( Bits )
import Data.ByteString
    ( ByteString )
import Data.Foldable
    ( fold )
import Data.Function
    ( (&) )
import Data.Functor
    ( void, (<&>) )
import Data.Functor.Contravariant
    ( (>$<) )
import qualified Data.HashMap.Strict as HashMap
import Data.IntCast
    ( intCast, intCastMaybe )
import Data.List
    ( partition )
import Data.Map
    ( Map )
import Data.Maybe
    ( catMaybes, fromMaybe )
import Data.Proxy
    ( Proxy (..) )
import Data.Quantity
    ( MkPercentageError (PercentageOutOfBoundsError)
    , Quantity (..)
    , mkPercentage
    )
import Data.Scientific
    ( Scientific, isInteger, toBoundedInteger )
import Data.Set
    ( Set )
import Data.Text
    ( Text )
import Data.Text.Class
    ( FromText (fromText), TextDecodingError (..), ToText (..) )
import Data.Text.Encoding
    ( encodeUtf8 )
import Data.These
    ( These (That, These, This) )
import Data.Traversable
    ( for )
import Data.Word
    ( Word64 )
import Fmt
    ( pretty )
import GHC.OldList
    ( sortOn )
import GHC.Stack
    ( HasCallStack )
import Money
    ( Discrete' )
import Ouroboros.Consensus.Block.Abstract
    ( EpochSize (EpochSize) )
import Ouroboros.Consensus.BlockchainTime.WallClock.Types
    ( RelativeTime (..), mkSlotLength )
import Ouroboros.Consensus.Cardano.Block
    ( CardanoBlock, StandardCrypto )
import Ouroboros.Consensus.HardFork.History.EraParams
    ( EraParams (EraParams, eraEpochSize, eraSafeZone, eraSlotLength)
    , SafeZone (..)
    )
import Ouroboros.Consensus.HardFork.History.Summary
    ( Bound (Bound, boundEpoch, boundSlot, boundTime)
    , EraEnd (EraEnd, EraUnbounded)
    , EraSummary (EraSummary, eraEnd, eraParams, eraStart)
    , Summary (..)
    )
import Ouroboros.Consensus.Util.Counting
    ( NonEmpty (NonEmptyCons, NonEmptyOne) )
import Servant.Client
    ( runClientM )
import Text.Read
    ( readEither, readMaybe )
import UnliftIO
    ( throwIO )
import UnliftIO.Async
    ( async, link )
import UnliftIO.Exception
    ( Exception )


{-------------------------------------------------------------------------------
    NetworkLayer
-------------------------------------------------------------------------------}
data BlockfrostError
    = ClientError BF.BlockfrostError
    | NoSlotError BF.Block
    | IntegralCastError String
    | NoBlockHeight BF.Block
    | InvalidBlockHash BF.BlockHash TextDecodingError
    | InvalidTxMetadataLabel String
    | InvalidTxMetadataValue String
    | InvalidTxHash Text TextDecodingError
    | InvalidAddress Text TextDecodingError
    | InvalidPoolId Text TextDecodingError
    | InvalidDecentralizationLevelPercentage Double
    | InvalidUtxoInputAmount BF.UtxoInput
    | InvalidUtxoOutputAmount BF.UtxoOutput
    | UnknownEraForEpoch EpochNo
    deriving (Show, Eq)

newtype BlockfrostException = BlockfrostException BlockfrostError
    deriving stock (Show)
    deriving anyclass (Exception)

data Log
    = MsgWatcherUpdate BlockHeader BracketLog
    | MsgTimeInterpreterLog TimeInterpreterLog
    | MsgLightLayerLog LN.LightLayerLog

instance ToText Log where
    toText = \case
        MsgWatcherUpdate blockHeader bracketLog ->
            "Update watcher with tip: " <> pretty blockHeader <>
            ". Callback " <> toText bracketLog <> ". "
        MsgTimeInterpreterLog til ->
            toText til
        MsgLightLayerLog l ->
            toText l

instance HasSeverityAnnotation Log where
    getSeverityAnnotation = \case
      MsgWatcherUpdate _ _ -> Info
      MsgTimeInterpreterLog _ -> Info
      MsgLightLayerLog l -> getSeverityAnnotation l

withNetworkLayer
    :: Tracer IO Log
    -> SomeNetworkDiscriminant
    -> NetworkParameters
    -> BF.Project
    -> (NetworkLayer IO (CardanoBlock StandardCrypto) -> IO a)
    -> IO a
withNetworkLayer tr network np project k = do
    bfConfig <- newClientConfig project
    k NetworkLayer
        { chainSync = \_tr _chainFollower -> pure ()
        , lightSync = Just $ blockfrostLightSync bfConfig
        , currentNodeTip
        , currentNodeEra
        , currentProtocolParameters
        , currentSlottingParameters = undefined
        , watchNodeTip
        , postTx = undefined
        , stakeDistribution = undefined
        , getCachedRewardAccountBalance
        , fetchRewardAccountBalances = fetchNetworkRewardAccountBalances network
        , timeInterpreter = timeInterpreterFromStartTime getGenesisBlockDate
        , syncProgress = undefined
        }
  where
    NetworkParameters
        { genesisParameters = GenesisParameters { getGenesisBlockDate } } = np

    networkId = networkDiscriminantToId network

    currentNodeTip :: IO BlockHeader
    currentNodeTip = runBlockfrost BF.getLatestBlock
    -- ^ TODO: use cached value while retrying

    watchNodeTip :: (BlockHeader -> IO ()) -> IO ()
    watchNodeTip callback = link =<< async (pollNodeTip callback)
      where
        pollNodeTip :: (BlockHeader -> IO ()) -> IO ()
        pollNodeTip cb = forever $ do
            header <- runBlockfrost BF.getLatestBlock
            bracketTracer (MsgWatcherUpdate header >$< tr) $ cb header
            threadDelay 2_000_000

    currentProtocolParameters :: IO ProtocolParameters
    currentProtocolParameters = runBlockfrost BF.getLatestEpochProtocolParams

    currentNodeEra :: IO AnyCardanoEra
    currentNodeEra = handleBlockfrostError $ do
        BF.EpochInfo {_epochInfoEpoch} <- liftBlockfrost BF.getLatestEpoch
        epoch <- fromBlockfrostM _epochInfoEpoch
        liftEither $ eraByEpoch networkId epoch

    timeInterpreterFromStartTime ::
        StartTime -> TimeInterpreter (ExceptT PastHorizonException IO)
    timeInterpreterFromStartTime startTime =
        mkTimeInterpreter (MsgTimeInterpreterLog >$< tr) startTime $
            pure $ HF.mkInterpreter $ networkSummary networkId

    fetchNetworkRewardAccountBalances  ::
        SomeNetworkDiscriminant ->
        Set RewardAccount ->
        IO (Map RewardAccount Coin)
    fetchNetworkRewardAccountBalances
        (SomeNetworkDiscriminant (Proxy :: Proxy nd)) accounts =
        handleBlockfrostError . fmap Map.fromList $
            for (Set.toList accounts) $ \rewardAccount -> do
                BF.AccountInfo {..} <- liftBlockfrost $ BF.getAccount $
                    BF.mkAddress $ encodeStakeAddress @nd rewardAccount
                coin <- fromIntegral @_ @Integer _accountInfoRewardsSum <?#>
                    "AccountInfoRewardsSum"
                pure (rewardAccount, Coin coin)

    getCachedRewardAccountBalance :: RewardAccount -> IO Coin
    getCachedRewardAccountBalance account =
        fromMaybe (Coin 0) . Map.lookup account <$>
            fetchNetworkRewardAccountBalances network (Set.singleton account)

    runBlockfrost ::
        forall b w. FromBlockfrost b w => BF.BlockfrostClientT IO b -> IO w
    runBlockfrost =
        handleBlockfrostError . (fromBlockfrostM @b @w <=< liftBlockfrost)

    liftBlockfrost :: BF.BlockfrostClientT IO a -> ExceptT BlockfrostError IO a
    liftBlockfrost =
        withExceptT ClientError . ExceptT . BF.runBlockfrostClientT project

    blockfrostLightSync ::
        BF.ClientConfig ->
        ChainFollower
            IO
            ChainPoint
            BlockHeader
            (LightBlocks IO Block addr txs)
        -> IO ()
    blockfrostLightSync bfConfig follower = do
        AnyCardanoEra era <- currentNodeEra
        let stabilityWindow =
                fromIntegral . getQuantity $ case cardanoEraStyle era of
                    LegacyByronEra ->
                        stabilityWindowByron $ slottingParameters np
                    ShelleyBasedEra _ ->
                        stabilityWindowShelley $ slottingParameters np
        let isConsensus = \case
                ChainPointAtGenesis -> pure True
                ChainPoint (SlotNo slot) blockHeaderHash -> do
                    BF.Block {_blockHash = BF.BlockHash bfHeaderHash} <-
                        BF.getBlockSlot (BF.Slot (toInteger slot))
                    pure $ bfHeaderHash == toText blockHeaderHash
        let getBlockHeaderAtHeight :: Integer -> IO (Maybe BlockHeader)
            getBlockHeaderAtHeight height =
                either (error . show) Just . fromBlockfrost <$>
                    BF.getBlock (Left height)
        let genesisHeader = BlockHeader
                { slotNo = SlotNo 0
                , blockHeight = Quantity 0
                , parentHeaderHash = Nothing
                , headerHash = either (error . show) id $ fromText
                    "5f20df933584822601f9e3f8c024eb5e\
                    \b252fe8cefb24d1317dc3d432e940ebb"
                }
        let getBlockHeaderAt :: ChainPoint -> IO (Maybe BlockHeader)
            getBlockHeaderAt = \case
                ChainPointAtGenesis -> pure $ Just genesisHeader
                ChainPoint (SlotNo slot) blockHeaderHash -> do
                    b@BF.Block {_blockHash = BF.BlockHash bfHeaderHash} <-
                        BF.getBlockSlot (BF.Slot (toInteger slot))
                    pure $ if bfHeaderHash == toText blockHeaderHash
                        then either (error . show) Just $ fromBlockfrost b
                        else Nothing
        -- The the next blocks starting at the given 'ChainPoint'.
        -- Return 'Nothing' if hte point is not consensus anymore.
        let getNextBlocks :: ChainPoint -> IO (Maybe [Block])
            getNextBlocks = \case
                ChainPointAtGenesis -> pure $ Just
                    [ Block
                        { header = genesisHeader
                        , transactions = undefined --  :: ![Tx]
                        , delegations = [] --  :: ![DelegationCertificate]
                        }
                    ]
                ChainPoint _slotNo hash ->
                    -- Only one block is fetched for now, even though the type
                    -- allows for a list of blocks
                    Just . pure <$> runBFM bfConfig (fetchBlock network hash)
        -- Transactions for a given address and point range.
        let getAddressTxs :: BlockHeader -> BlockHeader -> addr -> IO txs
            getAddressTxs = undefined
        let lightSyncSource :: LightSyncSource IO Block addr txs
            lightSyncSource =
                LightSyncSource
                    { stabilityWindow
                    , getHeader = header
                    , getTip = currentNodeTip
                    , isConsensus
                    , getBlockHeaderAtHeight
                    , getBlockHeaderAt
                    , getNextBlocks
                    , getAddressTxs
                    }
        void $ LN.lightSync (MsgLightLayerLog >$< tr) lightSyncSource follower

fetchBlock
    :: forall m
     . ( MonadError BlockfrostError m
       , BF.MonadBlockfrost m
       , MonadBaseControl IO m
       )
    => SomeNetworkDiscriminant
    -> Hash "BlockHeader"
    -> m Block
fetchBlock nd hash = do
    let blockHash = BF.BlockHash (toText hash)
    block@BF.Block {..} <- BF.getBlock $ Right blockHash
    header <- fromBlockfrostM block
    txHashes <- fetchTxHashes blockHash _blockTxCount
    transactions <- mapConcurrently (fetchTransaction nd) txHashes
    delegations <- join <$> mapConcurrently (fetchDelegation nd) txHashes
    pure Block
        { header
        , transactions
        , delegations
        }
  where
    fetchTxHashes :: BF.BlockHash -> Integer -> m [BF.TxHash]
    fetchTxHashes blockHash =
        fmap concat . traverse (fetchPage blockHash) . pages

    fetchPage :: BF.BlockHash -> BF.Paged -> m [BF.TxHash]
    fetchPage blockHash page =
        BF.getBlockTxs' (Right blockHash) page BF.Ascending

    pages :: Integer -> [BF.Paged]
    pages count =
        pageNumbers <&> \pageNumber -> BF.Paged { countPerPage, pageNumber }
        where
        countPerPage :: Int = 100
        pageNumbers = [1 .. lastPage]
        lastPage :: Int = fromIntegral $
            let (numWholePages, numLast) = quotRem count (intCast countPerPage)
            in if numLast == 0 then numWholePages else succ numWholePages

fetchDelegation
    :: forall m
     . ( MonadError BlockfrostError m
       , BF.MonadBlockfrost m
       , MonadBaseControl IO m
       )
    => SomeNetworkDiscriminant
    -> BF.TxHash
    -> m [DelegationCertificate]
fetchDelegation (SomeNetworkDiscriminant (Proxy :: Proxy nd)) hash = do
    delegations <- concurrently (BF.getTxDelegations hash) (BF.getTxStakes hash)
    certs <- liftEither $ for (uncurry align delegations) $ \case
        This txDelegation -> pure <$> parseTxDelegation txDelegation
        That txStake -> pure <$> parseTxStake txStake
        These txDelegation txStake ->
            (\d s -> [d, s])
                <$> parseTxDelegation txDelegation
                <*> parseTxStake txStake
    pure $ snd <$> sortOn fst (concat certs)
  where
    parseTxDelegation BF.TransactionDelegation{..} = do
        let addr = BF.unAddress _transactionDelegationAddress
        rewardAccount <-
            first (InvalidAddress addr) $ decodeStakeAddress @nd addr
        poolId <-
            first (InvalidPoolId addr) . decodePoolIdBech32 $
                BF.unPoolId _transactionDelegationPoolId
        pure ( _transactionDelegationCertIndex
             , CertDelegateFull rewardAccount poolId
             )
    parseTxStake BF.TransactionStake{..} = do
        let addr = BF.unAddress _transactionStakeAddress
        rewardAccount <-
            first (InvalidAddress addr) $ decodeStakeAddress @nd addr
        let action = if _transactionStakeRegistration
                then CertRegisterKey
                else CertDelegateNone
        pure (_transactionStakeCertIndex, action rewardAccount)

fetchTransaction
    :: forall m
     . (MonadError BlockfrostError m, BF.MonadBlockfrost m)
    => SomeNetworkDiscriminant
    -> BF.TxHash
    -> m Tx
fetchTransaction nd hash = do
  transaction <- BF.getTx hash
  utxos <- BF.getTxUtxos hash
  withdrawals <- BF.getTxWithdrawals hash
  metadata <- BF.getTxMetadataJSON hash
  assembleTransaction nd transaction utxos withdrawals metadata

assembleTransaction
    :: forall m
     . MonadError BlockfrostError m
    => SomeNetworkDiscriminant
    -> BF.Transaction
    -> BF.TransactionUtxos
    -> [BF.TransactionWithdrawal]
    -> [BF.TransactionMetaJSON]
    -> m Tx
assembleTransaction
    (SomeNetworkDiscriminant (Proxy :: Proxy nd))
    BF.Transaction{..}
    BF.TransactionUtxos{..}
    txWithdrawals
    metadataJSON = liftEither $ do
        txId <- parseTxHash _transactionHash
        let fee = Just $ Coin $ fromIntegral _transactionFees
        (resolvedInputs, resolvedCollateral) <-
                fromInputs _transactionUtxosInputs
        outputs <- for _transactionUtxosOutputs $ \out@BF.UtxoOutput{..} -> do
            let outAddr = BF.unAddress _utxoOutputAddress
            address <- either (throwError . InvalidAddress outAddr) pure $
                decodeAddress @nd outAddr
            tokens <- do
                coin <- case [ lovelaces
                             | BF.AdaAmount lovelaces <- _utxoOutputAmount ] of
                    [l] -> fromBlockfrost l
                    _ -> throwError $ InvalidUtxoOutputAmount out
                pure $ TokenBundle coin mempty -- TODO: Handle native assets
            pure TxOut{..}
        withdrawals <- Map.fromList <$>
            for txWithdrawals ( \BF.TransactionWithdrawal{..} -> do
                let addr = BF.unAddress _transactionWithdrawalAddress
                rewardAccount <-
                    first (InvalidAddress addr) $ decodeStakeAddress @nd addr
                coin <- fromBlockfrost _transactionWithdrawalAmount
                pure (rewardAccount, coin)
            )
        metadata <-
            if null metadataJSON
            then pure Nothing
            else Just . TxMetadata . Map.fromList . catMaybes <$>
                for metadataJSON ( \BF.TransactionMetaJSON{..} -> do
                    label <- either (throwError . InvalidTxMetadataLabel) pure $
                        readEither (T.unpack _transactionMetaJSONLabel)
                    fmap (label,) <$> for _transactionMetaJSONJSONMetadata
                        (first InvalidTxMetadataValue . unmarshalMetadataValue)
                    )
        let scriptValidity = Just $
                if _transactionValidContract
                    then TxScriptValid
                    else TxScriptInvalid
        pure Tx
            { txId
            , fee
            , resolvedCollateral
            , resolvedInputs
            , outputs
            , withdrawals
            , metadata
            , scriptValidity
            }

  where
    unmarshalMetadataValue :: Json.Value -> Either String TxMetadataValue
    unmarshalMetadataValue = \case
        Json.Object hm ->
            TxMetaMap <$> for (HashMap.toList hm)
                ( bitraverse
                    (unmarshalMetadataValue . Json.String)
                    unmarshalMetadataValue
                )
        Json.Array vec ->
            TxMetaList . Vec.toList <$> for vec unmarshalMetadataValue
        Json.String txt ->
            Right $ TxMetaText txt
        Json.Number sci ->
            if isInteger sci
                then Right (TxMetaNumber (truncate sci))
                else Left "Non-integer metadata value"
        Json.Bool b ->
            Left $ "Expected TxMetadataValue but got bool (" <> show b <> ")"
        Json.Null ->
            Left "Expected TxMetadataValue but got null"

    fromInputs
        :: [BF.UtxoInput]
        -> Either BlockfrostError ([(TxIn, Coin)], [(TxIn, Coin)])
    fromInputs utxos =
        bitraverse f f $ partition BF._utxoInputCollateral utxos
      where
        f :: [BF.UtxoInput] -> Either BlockfrostError [(TxIn, Coin)]
        f = traverse $ \input@BF.UtxoInput{..} -> do
            txHash <- parseTxHash _utxoInputTxHash
            txIndex <- _utxoInputOutputIndex <?#> "_utxoInputOutputIndex"
            coin <-
                case [ lovelaces
                        | BF.AdaAmount lovelaces <- _utxoInputAmount ] of
                    [l] -> fromBlockfrost l
                    _ -> throwError $ InvalidUtxoInputAmount input
            pure (TxIn txHash txIndex, coin)

    parseTxHash hash =
        either (throwError . InvalidTxHash hash) pure $ fromText hash

class FromBlockfrost b w where
    fromBlockfrost :: b -> Either BlockfrostError w

fromBlockfrostM
    :: FromBlockfrost b w => MonadError BlockfrostError m => b -> m w
fromBlockfrostM = liftEither . fromBlockfrost



instance FromBlockfrost BF.Block BlockHeader where
    fromBlockfrost block@BF.Block{..} = do
        slotNo <- _blockSlot <?> NoSlotError block >>= fromBlockfrostM
        blockHeight <-
            _blockHeight <?> NoBlockHeight block >>=
                (Quantity <$>) . (<?#> "BlockHeight")
        headerHash <- parseBlockHeader _blockHash
        parentHeaderHash <- for _blockPreviousBlock parseBlockHeader
        pure BlockHeader { slotNo, blockHeight, headerHash, parentHeaderHash }
      where
        parseBlockHeader blockHash =
            case fromText (BF.unBlockHash blockHash) of
                Right hash -> pure hash
                Left tde -> throwError $ InvalidBlockHash blockHash tde

instance FromBlockfrost BF.ProtocolParams ProtocolParameters where
    fromBlockfrost BF.ProtocolParams{..} = do
        decentralizationLevel <-
            let percentage = mkPercentage $
                    toRational _protocolParamsDecentralisationParam
            in case percentage of
                Left PercentageOutOfBoundsError ->
                    throwError $ InvalidDecentralizationLevelPercentage
                        _protocolParamsDecentralisationParam
                Right level -> pure $ DecentralizationLevel level
        minFeeA <-
            _protocolParamsMinFeeA <?#> "MinFeeA"
        minFeeB <-
            _protocolParamsMinFeeB <?#> "MinFeeB"
        maxTxSize <-
            _protocolParamsMaxTxSize <?#> "MaxTxSize"
        maxValSize <-
            BF.unQuantity _protocolParamsMaxValSize <?#> "MaxValSize"
        maxTxExSteps <-
            BF.unQuantity _protocolParamsMaxTxExSteps <?#> "MaxTxExSteps"
        maxBlockExSteps <-
            BF.unQuantity _protocolParamsMaxBlockExSteps <?#> "MaxBlockExSteps"
        maxBlockExMem <-
            BF.unQuantity _protocolParamsMaxBlockExMem <?#> "MaxBlockExMem"
        maxTxExMem <-
            BF.unQuantity _protocolParamsMaxTxExMem <?#> "MaxTxExMem"
        desiredNumberOfStakePools <-
            _protocolParamsNOpt <?#> "NOpt"
        minimumUTxOvalue <-
            MinimumUTxOValueCostPerWord . Coin <$>
                intCast @_ @Integer _protocolParamsCoinsPerUtxoWord
                    <?#> "CoinsPerUtxoWord"
        stakeKeyDeposit <-
            Coin <$>
                intCast @_ @Integer _protocolParamsKeyDeposit <?#> "KeyDeposit"
        maxCollateralInputs <-
            _protocolParamsMaxCollateralInputs <?#> "MaxCollateralInputs"
        collateralPercent <-
            _protocolParamsCollateralPercent <?#> "CollateralPercent"
        protoMajorVer <-
            _protocolParamsProtocolMajorVer <?#> "ProtocolMajorVer"
        protoMinorVer <-
            _protocolParamsProtocolMinorVer <?#> "ProtocolMinorVer"
        maxBlockHeaderSize <-
            _protocolParamsMaxBlockHeaderSize <?#> "MaxBlockHeaderSize"
        maxBlockBodySize <-
            _protocolParamsMaxBlockSize <?#> "MaxBlockBodySize"
        eMax <-
            _protocolParamsEMax <?#> "EMax"
        nOpt <-
            _protocolParamsNOpt <?#> "NOpt"

        pure ProtocolParameters
            { eras = emptyEraInfo
            , txParameters = TxParameters
                { getFeePolicy =
                    LinearFee $ LinearFunction
                        { intercept = fromIntegral minFeeB
                        , slope = fromIntegral minFeeA
                        }
                , getTxMaxSize =
                    Quantity maxTxSize
                , getTokenBundleMaxSize =
                    TokenBundleMaxSize $ TxSize maxValSize
                , getMaxExecutionUnits =
                    ExecutionUnits
                        { executionSteps = maxTxExSteps
                        , executionMemory = maxTxExMem
                        }
                }
            , executionUnitPrices = Just $ ExecutionUnitPrices
                { pricePerStep = toRational _protocolParamsPriceStep
                , pricePerMemoryUnit = toRational _protocolParamsPriceMem
                }
            , maximumCollateralInputCount = maxCollateralInputs
            , minimumCollateralPercentage = collateralPercent
            , currentNodeProtocolParameters = Just Node.ProtocolParameters
                { protocolParamProtocolVersion =
                    (protoMajorVer, protoMinorVer)
                , protocolParamDecentralization =
                    toRational _protocolParamsDecentralisationParam
                , protocolParamExtraPraosEntropy = Nothing
                , protocolParamMaxBlockHeaderSize = maxBlockHeaderSize
                , protocolParamMaxBlockBodySize = maxBlockBodySize
                , protocolParamMaxTxSize = intCast maxTxSize
                , protocolParamTxFeeFixed = minFeeB
                , protocolParamTxFeePerByte = minFeeA
                , protocolParamMinUTxOValue =
                    Just $ Node.Lovelace $ intCast _protocolParamsMinUtxo
                , protocolParamStakeAddressDeposit =
                    Node.Lovelace $
                        intCast @_ @Integer _protocolParamsKeyDeposit
                , protocolParamStakePoolDeposit =
                    Node.Lovelace $
                        intCast @_ @Integer _protocolParamsPoolDeposit
                , protocolParamMinPoolCost =
                    Node.Lovelace $
                        intCast @_ @Integer _protocolParamsMinPoolCost
                , protocolParamPoolRetireMaxEpoch = Node.EpochNo eMax
                , protocolParamStakePoolTargetNum = nOpt
                , protocolParamPoolPledgeInfluence =
                    toRational _protocolParamsA0
                , protocolParamMonetaryExpansion = toRational _protocolParamsRho
                , protocolParamTreasuryCut = toRational _protocolParamsTau
                , protocolParamUTxOCostPerWord =
                    Just $ Node.Lovelace $
                        intCast _protocolParamsCoinsPerUtxoWord
                , protocolParamCostModels =
                    mempty
                    -- Cost models aren't available via BF
                    -- TODO: Hardcode or retrieve from elswhere.
                    -- https://input-output.atlassian.net/browse/ADP-1572
                , protocolParamPrices =
                    Just $ Node.ExecutionUnitPrices
                        { priceExecutionSteps =
                            toRational _protocolParamsPriceStep
                        , priceExecutionMemory =
                            toRational _protocolParamsPriceMem
                        }
                , protocolParamMaxTxExUnits =
                    Just $ Node.ExecutionUnits
                        { executionSteps = maxTxExSteps
                        , executionMemory = maxTxExMem
                        }
                , protocolParamMaxBlockExUnits =
                    Just $ Node.ExecutionUnits
                        { executionSteps = maxBlockExSteps
                        , executionMemory = maxBlockExMem
                        }
                , protocolParamMaxValueSize = Just maxValSize
                , protocolParamCollateralPercent = Just collateralPercent
                , protocolParamMaxCollateralInputs =
                    Just $ intCast maxCollateralInputs
                }
            , ..
            }

instance FromBlockfrost BF.TxHash (Hash "Tx") where
    fromBlockfrost txHash =
        let hash = BF.unTxHash txHash
        in first (InvalidTxHash hash) $ fromText hash

instance FromBlockfrost BF.Slot SlotNo where
    fromBlockfrost = fmap SlotNo . (<?#> "SlotNo") . BF.unSlot

instance FromBlockfrost BF.Epoch EpochNo where
    fromBlockfrost = pure . fromIntegral

-- type Lovelaces = Discrete' "ADA" '(1000000, 1)
instance FromBlockfrost (Discrete' "ADA" '(1000000, 1)) Coin where
  fromBlockfrost lovelaces =
    Coin <$> (intCast @_ @Integer lovelaces <?#> "Lovelaces")

networkSummary :: NetworkId -> Summary (OC.CardanoEras OC.StandardCrypto)
networkSummary = \case
    Mainnet ->
        Summary
            { getSummary =
            -- Byron
            NonEmptyCons EraSummary
                { eraStart = Bound
                    { boundTime = RelativeTime 0
                    , boundSlot = 0
                    , boundEpoch = 0
                    }
                , eraEnd = EraEnd Bound
                    { boundTime = RelativeTime 89856000
                    , boundSlot = 4492800
                    , boundEpoch = Node.EpochNo 208
                    }
                , eraParams = EraParams
                    { eraEpochSize = EpochSize 21600
                    , eraSlotLength = mkSlotLength 20
                    , eraSafeZone = StandardSafeZone 4320
                    }
                }
            -- Shelley
            $ NonEmptyCons EraSummary
                { eraStart = Bound
                    { boundTime = RelativeTime 89856000
                    , boundSlot = 4492800
                    , boundEpoch = Node.EpochNo 208
                    }
                , eraEnd = EraEnd Bound
                    { boundTime = RelativeTime 101952000
                    , boundSlot = 16588800
                    , boundEpoch = Node.EpochNo 236
                    }
                , eraParams = EraParams
                    { eraEpochSize = EpochSize 432000
                    , eraSlotLength = mkSlotLength 1
                    , eraSafeZone = StandardSafeZone 129600
                    }
                }
            -- Allegra
            $ NonEmptyCons EraSummary
                { eraStart = Bound
                    { boundTime = RelativeTime 101952000
                    , boundSlot = 16588800
                    , boundEpoch = Node.EpochNo 236
                    }
                , eraEnd = EraEnd Bound
                    { boundTime = RelativeTime 108432000
                    , boundSlot = 23068800
                    , boundEpoch = Node.EpochNo 251
                    }
                , eraParams = EraParams
                    { eraEpochSize = EpochSize 432000
                    , eraSlotLength = mkSlotLength 1
                    , eraSafeZone = StandardSafeZone 129600
                    }
                }
            -- Mary
            $ NonEmptyCons EraSummary
                { eraStart = Bound
                    { boundTime = RelativeTime 108432000
                    , boundSlot = 23068800
                    , boundEpoch = Node.EpochNo 251
                    }
                , eraEnd = EraEnd Bound
                    { boundTime = RelativeTime 125280000
                    , boundSlot = 39916800
                    , boundEpoch = Node.EpochNo 290
                    }
                , eraParams = EraParams
                    { eraEpochSize = EpochSize 432000
                    , eraSlotLength = mkSlotLength 1
                    , eraSafeZone = StandardSafeZone 129600
                    }
                }
            -- Alonzo
            $ NonEmptyOne EraSummary
                { eraStart = Bound
                    { boundTime = RelativeTime 125280000
                    , boundSlot = 39916800
                    , boundEpoch = Node.EpochNo 290
                    }
                , eraEnd = EraUnbounded
                , eraParams = EraParams
                    { eraEpochSize = EpochSize 432000
                    , eraSlotLength = mkSlotLength 1
                    , eraSafeZone = StandardSafeZone 129600
                    }
                }
            }
    Testnet (NetworkMagic 1097911063) -> -- Magic of the current public testnet
        Summary
            { getSummary
                = NonEmptyCons EraSummary
                    { eraStart = Bound
                        { boundTime = RelativeTime 0
                        , boundSlot = SlotNo 0
                        , boundEpoch = Node.EpochNo 0
                        }
                    , eraEnd = EraEnd Bound
                        { boundTime = RelativeTime 31968000
                        , boundSlot = SlotNo 1598400
                        , boundEpoch = Node.EpochNo 74
                        }
                    , eraParams = EraParams
                        { eraEpochSize = EpochSize 21600
                        , eraSlotLength = mkSlotLength 20
                        , eraSafeZone = StandardSafeZone 4320
                        }
                    }
                $ NonEmptyCons EraSummary
                    { eraStart = Bound
                        { boundTime = RelativeTime 31968000
                        , boundSlot = SlotNo 1598400
                        , boundEpoch = Node.EpochNo 74
                        }
                    , eraEnd = EraEnd Bound
                        { boundTime = RelativeTime 44064000
                        , boundSlot = SlotNo 13694400
                        , boundEpoch = Node.EpochNo 102
                        }
                    , eraParams = EraParams
                        { eraEpochSize = EpochSize 432000
                        , eraSlotLength = mkSlotLength 1
                        , eraSafeZone = StandardSafeZone 129600
                        }
                    }
                $ NonEmptyCons EraSummary
                    { eraStart = Bound
                        { boundTime = RelativeTime 44064000
                        , boundSlot = SlotNo 13694400
                        , boundEpoch = Node.EpochNo 102
                        }
                    , eraEnd = EraEnd Bound
                        { boundTime = RelativeTime 48384000
                        , boundSlot = SlotNo 18014400
                        , boundEpoch = Node.EpochNo 112
                        }
                    , eraParams = EraParams
                        { eraEpochSize = EpochSize 432000
                        , eraSlotLength = mkSlotLength 1
                        , eraSafeZone = StandardSafeZone 129600
                        }
                    }
                $ NonEmptyCons EraSummary
                    { eraStart = Bound
                        { boundTime = RelativeTime 48384000
                        , boundSlot = SlotNo 18014400
                        , boundEpoch = Node.EpochNo 112
                        }
                    , eraEnd = EraEnd Bound
                        { boundTime = RelativeTime 66528000
                        , boundSlot = SlotNo 36158400
                        , boundEpoch = Node.EpochNo 154
                        }
                    , eraParams = EraParams
                        { eraEpochSize = EpochSize 432000
                        , eraSlotLength = mkSlotLength 1
                        , eraSafeZone = StandardSafeZone 129600
                        }
                    }
                $ NonEmptyOne EraSummary
                    { eraStart = Bound
                        { boundTime = RelativeTime 66528000
                        , boundSlot = SlotNo 36158400
                        , boundEpoch = Node.EpochNo 154
                        }
                    , eraEnd = EraUnbounded
                    , eraParams = EraParams
                        { eraEpochSize = EpochSize 432000
                        , eraSlotLength = mkSlotLength 1
                        , eraSafeZone = StandardSafeZone 129600
                        }
                    }
            }
    Testnet magic ->
        error $ "Epoch/Era conversion isn't provided for the Testnet "
            <> show magic

{- Epoch-to-Era translation is not available in the Blockfrost API.

The following histories are hardcoded in order to work around this limitation:

For the Mainnet:      For the Testnet:
┌───────┬─────────┐   ┌───────┬─────────┐
│ Epoch │   Era   │   │ Epoch │   Era   │
├───────┼─────────┤   ├───────┼─────────┤
│  ...  │ Alonzo  │   │  ...  │ Alonzo  │
│  290  │ Alonzo  │   │  154  │ Alonzo  │
├───────┼─────────┤   ├───────┼─────────┤
│  289  │  Mary   │   │  153  │  Mary   │
│  ...  │  Mary   │   │  ...  │  Mary   │
│  251  │  Mary   │   │  112  │  Mary   │
├───────┼─────────┤   ├───────┼─────────┤
│  250  │ Allegra │   │  111  │ Allegra │
│  ...  │ Allegra │   │  ...  │ Allegra │
│  236  │ Allegra │   │  102  │ Allegra │
├───────┼─────────┤   ├───────┼─────────┤
│  235  │ Shelley │   │  101  │ Shelley │
│  ...  │ Shelley │   │  ...  │ Shelley │
│  208  │ Shelley │   │   74  │ Shelley │
├───────┼─────────┤   ├───────┼─────────┤
│  207  │  Byron  │   │   73  │  Byron  │
│  ...  │  Byron  │   │  ...  │  Byron  │
│    0  │  Byron  │   │    0  │  Byron  │
└───────┴─────────┘   └───────┴─────────┘

-}
eraByEpoch :: NetworkId -> EpochNo -> Either BlockfrostError AnyCardanoEra
eraByEpoch networkId epoch =
    case dropWhile ((> epoch) . snd) (reverse eraBoundaries) of
        (era, _) : _ -> Right era
        _ -> Left $ UnknownEraForEpoch epoch
  where
    eraBoundaries :: [(Node.AnyCardanoEra, EpochNo)]
    eraBoundaries =
        [minBound .. maxBound] <&> \era -> (era, epochEraStartsAt era)
      where
        -- When new era is added this function reminds to update itself:
        -- "Pattern match(es) are non-exhaustive"
        epochEraStartsAt :: Node.AnyCardanoEra -> EpochNo
        epochEraStartsAt era = EpochNo $ case networkId of
            Mainnet ->
                case era of
                    AnyCardanoEra AlonzoEra  -> 290
                    AnyCardanoEra MaryEra    -> 251
                    AnyCardanoEra AllegraEra -> 236
                    AnyCardanoEra ShelleyEra -> 208
                    AnyCardanoEra ByronEra   -> 0
            Testnet (NetworkMagic 1097911063) ->
                case era of
                    AnyCardanoEra AlonzoEra  -> 154
                    AnyCardanoEra MaryEra    -> 112
                    AnyCardanoEra AllegraEra -> 102
                    AnyCardanoEra ShelleyEra -> 74
                    AnyCardanoEra ByronEra   -> 0
            Testnet magic ->
                error $ "Epoch/Era conversion isn't provided for the Testnet "
                    <> show magic <> " in light mode."


-- | Raises an error in case of an absent value
(<?>) :: MonadError e m => Maybe a -> e -> m a
(<?>) Nothing e = throwError e
(<?>) (Just a) _ = pure a

infixl 8 <?>
{-# INLINE (<?>) #-}

-- | Casts integral values safely or raises an `IntegralCastError`
(<?#>) ::
    ( MonadError BlockfrostError m
    , Integral a, Integral b
    , Bits a, Bits b
    ) =>
    a -> String -> m b
(<?#>) a e = intCastMaybe a <?> IntegralCastError e

infixl 8 <?#>
{-# INLINE (<?#>) #-}


{-------------------------------------------------------------------------------
    Stake Pools
-------------------------------------------------------------------------------}
-- | Estimate the performance of a stake pool based on
-- the past 50 epochs (or less if the pool is younger than that).
--
-- Uses 'estimatePoolPerformance' from "Cardano.Pool.Rank.Likelihood"
-- for this purpose.
getPoolPerformanceEstimate
    :: BF.MonadBlockfrost m
    => SlottingParameters
    -> DecentralizationLevel
    -> RewardParams
    -> BF.PoolId
    -> m PerformanceEstimate
getPoolPerformanceEstimate sp dl rp pid = do
    hist <- BF.getPoolHistory' pid get50 BF.Descending
    pure
        . estimatePoolPerformance sp dl
        . Seq.fromList . map toBlockProduction
        $ hist
  where
    get50 = BF.Paged { BF.countPerPage = 50, BF.pageNumber = 1 }
    toBlockProduction p = BlockProduction
        { blocksProduced = fromIntegral $ BF._poolHistoryBlocks p
        , stakeRelative =
            fromIntegral (BF._poolHistoryActiveStake p)
            / fromIntegral (unCoin $ totalStake rp)
            -- _poolHistoryActiveSize would be incorrect here
        }

newtype BFM a = BFM (ReaderT BF.ClientConfig (ExceptT BlockfrostError IO) a)
    deriving newtype
        ( Functor
        , Applicative
        , Monad
        , MonadIO
        , MonadBase IO
        , MonadBaseControl IO
        , MonadReader BF.ClientConfig
        , MonadError BlockfrostError
        )

instance BF.MonadBlockfrost BFM where
  getConf = ask
  liftBlockfrostClient act = BFM $ do
    env <- asks fst
    liftIO (runClientM act env) >>=
        either (throwError . ClientError . BF.fromServantClientError) pure

newClientConfig :: BF.Project -> IO BF.ClientConfig
newClientConfig prj = (, prj) <$> BF.newEnvByProject prj

runBFM :: BF.ClientConfig -> BFM a -> IO a
runBFM cfg (BFM c) = handleBlockfrostError (runReaderT c cfg)

handleBlockfrostError :: ExceptT BlockfrostError IO a -> IO a
handleBlockfrostError =
    either (throwIO . BlockfrostException) pure <=< runExceptT
