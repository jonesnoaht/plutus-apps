{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE MonoLocalBinds    #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications  #-}

module Plutus.ChainIndex.HandlersSpec (tests) where

import Control.Concurrent.STM (newTVarIO)
import Control.Lens (view)
import Control.Monad (forM)
import Control.Monad.Freer (Eff)
import Control.Monad.Freer.Extras.Beam (BeamEffect)
import Control.Monad.IO.Class (liftIO)
import Control.Tracer (nullTracer)
import Data.Default (def)
import Data.Set qualified as S
import Database.Beam.Migrate.Simple (autoMigrate)
import Database.Beam.Sqlite qualified as Sqlite
import Database.Beam.Sqlite.Migrate qualified as Sqlite
import Database.SQLite.Simple qualified as Sqlite
import Generators qualified as Gen
import Hedgehog (Property, assert, forAll, property, (===))
import Ledger (outValue)
import Plutus.ChainIndex (Page (pageItems), PageQuery (PageQuery), RunRequirements (..), appendBlock, citxOutputs,
                          runChainIndexEffects, txFromTxId, utxoSetMembership, utxoSetWithCurrency)
import Plutus.ChainIndex.ChainIndexError (ChainIndexError (..))
import Plutus.ChainIndex.DbSchema (checkedSqliteDb)
import Plutus.ChainIndex.Effects (ChainIndexControlEffect, ChainIndexQueryEffect)
import Plutus.ChainIndex.Tx (_ValidTx, citxTxId)
import Plutus.ChainIndex.Types (BlockProcessOption (..))
import Plutus.V1.Ledger.Ada qualified as Ada
import Plutus.V1.Ledger.Value (AssetClass (AssetClass), flattenValue)
import Test.Tasty
import Test.Tasty.Hedgehog (testProperty)
import Util (utxoSetFromBlockAddrs)

tests :: TestTree
tests = do
  testGroup "chain-index handlers"
    [ testGroup "txFromTxId"
      [ testProperty "get tx from tx id" txFromTxIdSpec
      ]
    , testGroup "utxoSetAtAddress"
      [ testProperty "each txOutRef should be unspent" eachTxOutRefAtAddressShouldBeUnspentSpec
      ]
    , testGroup "utxoSetWithCurrency"
      [ testProperty "each txOutRef should be unspent" eachTxOutRefWithCurrencyShouldBeUnspentSpec
      , testProperty "should restrict to non-ADA currencies" cantRequestForTxOutRefsWithAdaSpec
      ]
    , testGroup "BlockProcessOption"
      [ testProperty "do not store txs" doNotStoreTxs
      ]
    ]

-- | Tests we can correctly query a tx in the database using a tx id. We also
-- test with an non-existant tx id.
txFromTxIdSpec :: Property
txFromTxIdSpec = property $ do
  (tip, block@(fstTx:_)) <- forAll $ Gen.evalTxGenState Gen.genNonEmptyBlock
  unknownTxId <- forAll Gen.genRandomTxId
  txs <- liftIO $ Sqlite.withConnection ":memory:" $ \conn -> do
    Sqlite.runBeamSqlite conn $ autoMigrate Sqlite.migrationBackend checkedSqliteDb
    liftIO $ runChainIndex conn $ do
      appendBlock tip block def
      tx <- txFromTxId (view citxTxId fstTx)
      tx' <- txFromTxId unknownTxId
      pure (tx, tx')

  case txs of
    Right (Just tx, Nothing) -> fstTx === tx
    _                        -> Hedgehog.assert False

-- | After generating and appending a block in the chain index, verify that
-- querying the chain index with each of the addresses in the block returns
-- unspent 'TxOutRef's.
eachTxOutRefAtAddressShouldBeUnspentSpec :: Property
eachTxOutRefAtAddressShouldBeUnspentSpec = property $ do
  ((tip, block), state) <- forAll $ Gen.runTxGenState Gen.genNonEmptyBlock

  result <- liftIO $ Sqlite.withConnection ":memory:" $ \conn -> do
    Sqlite.runBeamSqlite conn $ autoMigrate Sqlite.migrationBackend checkedSqliteDb
    liftIO $ runChainIndex conn $ do
      -- Append the generated block in the chain index
      appendBlock tip block def
      utxoSetFromBlockAddrs block

  case result of
    Left _           -> Hedgehog.assert False
    Right utxoGroups -> S.fromList (concat utxoGroups) === view Gen.txgsUtxoSet state

-- | After generating and appending a block in the chain index, verify that
-- querying the chain index with each of the addresses in the block returns
-- unspent 'TxOutRef's.
eachTxOutRefWithCurrencyShouldBeUnspentSpec :: Property
eachTxOutRefWithCurrencyShouldBeUnspentSpec = property $ do
  ((tip, block), state) <- forAll $ Gen.runTxGenState Gen.genNonEmptyBlock

  let assetClasses =
        fmap (\(c, t, _) -> AssetClass (c, t))
             $ filter (\(c, t, _) -> not $ Ada.adaSymbol == c && Ada.adaToken == t)
             $ flattenValue
             $ view (traverse . citxOutputs . _ValidTx . traverse . outValue) block

  result <- liftIO $ Sqlite.withConnection ":memory:" $ \conn -> do
    Sqlite.runBeamSqlite conn $ autoMigrate Sqlite.migrationBackend checkedSqliteDb
    liftIO $ runChainIndex conn $ do
      -- Append the generated block in the chain index
      appendBlock tip block def

      forM assetClasses $ \ac -> do
        let pq = PageQuery 200 Nothing
        (_, utxoRefs) <- utxoSetWithCurrency pq ac
        pure $ pageItems utxoRefs

  case result of
    Left _           -> Hedgehog.assert False
    Right utxoGroups -> S.fromList (concat utxoGroups) === view Gen.txgsUtxoSet state

-- | Requesting UTXOs containing Ada should not return anything because every
-- transaction output must have a minimum of 1 ADA. So asking for UTXOs with ADA
-- will always return all UTXOs).
cantRequestForTxOutRefsWithAdaSpec :: Property
cantRequestForTxOutRefsWithAdaSpec = property $ do
  (tip, block) <- forAll $ Gen.evalTxGenState Gen.genNonEmptyBlock

  result <- liftIO $ Sqlite.withConnection ":memory:" $ \conn -> do
    Sqlite.runBeamSqlite conn $ autoMigrate Sqlite.migrationBackend checkedSqliteDb
    liftIO $ runChainIndex conn $ do
      -- Append the generated block in the chain index
      appendBlock tip block def

      let pq = PageQuery 200 Nothing
      (_, utxoRefs) <- utxoSetWithCurrency pq (AssetClass (Ada.adaSymbol, Ada.adaToken))
      pure $ pageItems utxoRefs

  case result of
    Left _         -> Hedgehog.assert False
    Right utxoRefs -> Hedgehog.assert $ null utxoRefs

-- | Do not store txs through BlockProcessOption.
-- The UTxO set must still be stored.
-- But cannot be fetched through addresses as addresses are not stored.
doNotStoreTxs :: Property
doNotStoreTxs = property $ do
  ((tip, block), state) <- forAll $ Gen.runTxGenState Gen.genNonEmptyBlock
  result <- liftIO $ Sqlite.withConnection ":memory:" $ \conn -> do
    Sqlite.runBeamSqlite conn $ autoMigrate Sqlite.migrationBackend checkedSqliteDb
    liftIO $ runChainIndex conn $ do
      appendBlock tip block BlockProcessOption{bpoStoreTxs=False}
      tx <- txFromTxId (view citxTxId (head block))
      utxosFromAddr <- utxoSetFromBlockAddrs block
      utxosStored <- traverse utxoSetMembership (S.toList (view Gen.txgsUtxoSet state))
      pure (tx, concat utxosFromAddr, utxosStored)
  case result of
    Right (Nothing, [], utxosStored) -> Hedgehog.assert $ and (snd <$> utxosStored)
    _                                -> Hedgehog.assert False

-- | Run a chain index action against a SQLite connection.
runChainIndex
  :: Sqlite.Connection
  -> Eff '[ ChainIndexQueryEffect
          , ChainIndexControlEffect
          , BeamEffect
          ] a
  -> IO (Either ChainIndexError a)
runChainIndex conn action = do
  stateTVar <- newTVarIO mempty
  (r, _) <- runChainIndexEffects (RunRequirements nullTracer stateTVar conn 10) action
  pure r
