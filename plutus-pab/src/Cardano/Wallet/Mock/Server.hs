{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DerivingStrategies    #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TypeApplications      #-}

module Cardano.Wallet.Mock.Server
    ( main
    ) where

import Cardano.BM.Data.Trace (Trace)
import Cardano.ChainIndex.Types (ChainIndexUrl (..))
import Cardano.Node.Client as NodeClient
import Cardano.Protocol.Socket.Mock.Client qualified as MockClient
import Cardano.Wallet.Mock.API (API)
import Cardano.Wallet.Mock.Handlers
import Cardano.Wallet.Mock.Types (Port (..), WalletConfig (..), WalletMsg (..), WalletUrl (..), Wallets, createWallet,
                                  getWalletInfo, multiWallet)
import Control.Concurrent.Availability (Availability, available)
import Control.Concurrent.MVar (MVar, newMVar)
import Control.Monad ((>=>))
import Control.Monad.Freer.Error (throwError)
import Control.Monad.Freer.Extras.Log (logInfo)
import Control.Monad.IO.Class (liftIO)
import Data.Coerce (coerce)
import Data.Either (fromRight)
import Data.Function ((&))
import Data.Map.Strict qualified as Map
import Data.Proxy (Proxy (Proxy))
import Ledger.CardanoWallet qualified as CW
import Ledger.Fee (FeeConfig)
import Ledger.TimeSlot (SlotConfig)
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Network.Wai.Handler.Warp qualified as Warp
import Plutus.PAB.Arbitrary ()
import Plutus.PAB.Monitoring.Monitoring qualified as LM
import Servant (Application, NoContent (..), err404, hoistServer, serve, (:<|>) ((:<|>)))
import Servant.Client (BaseUrl (baseUrlPort), ClientEnv, mkClientEnv)
import Wallet.Effects (balanceTx, submitTxn, totalFunds, walletAddSignature)
import Wallet.Emulator.Wallet (Wallet (..), WalletId)
import Wallet.Emulator.Wallet qualified as Wallet

app :: Trace IO WalletMsg
    -> MockClient.TxSendHandle
    -> NodeClient.ChainSyncHandle
    -> ClientEnv
    -> MVar Wallets
    -> FeeConfig
    -> SlotConfig
    -> Application
app trace txSendHandle chainSyncHandle chainIndexEnv mVarState feeCfg slotCfg =
    serve (Proxy @(API WalletId)) $
    hoistServer
        (Proxy @(API WalletId))
        (processWalletEffects trace txSendHandle chainSyncHandle chainIndexEnv mVarState feeCfg slotCfg) $
            createWallet :<|>
            (\w tx -> multiWallet (Wallet w) (submitTxn $ Right tx) >>= const (pure NoContent)) :<|>
            (getWalletInfo >=> maybe (throwError err404) pure ) :<|>
            (\w -> fmap (fmap (fromRight (error "Cardano.Wallet.Mock.Server: Expecting a mock tx, not an Alonzo tx when submitting it.")))
                 . multiWallet (Wallet w) . balanceTx) :<|>
            (\w -> multiWallet (Wallet w) totalFunds) :<|>
            (\w tx -> fmap (fromRight (error "Cardano.Wallet.Mock.Server: Expecting a mock tx, not an Alonzo tx when adding a signature."))
                    $ multiWallet (Wallet w) (walletAddSignature $ Right tx))

main :: Trace IO WalletMsg -> WalletConfig -> FeeConfig -> FilePath -> SlotConfig -> ChainIndexUrl -> Availability -> IO ()
main trace WalletConfig { baseUrl } feeCfg serverSocket slotCfg (ChainIndexUrl chainUrl) availability = LM.runLogEffects trace $ do
    chainIndexEnv <- buildEnv chainUrl defaultManagerSettings
    let knownWallets = Map.fromList $ zip Wallet.knownWallets (Wallet.fromMockWallet <$> CW.knownWallets)
    mVarState <- liftIO $ newMVar knownWallets
    txSendHandle    <- liftIO $ MockClient.runTxSender serverSocket
    chainSyncHandle <- Left <$> (liftIO $ MockClient.runChainSync' serverSocket slotCfg)
    logInfo $ StartingWallet (Port servicePort)
    liftIO $ Warp.runSettings warpSettings
           $ app trace
                 txSendHandle
                 chainSyncHandle
                 chainIndexEnv
                 mVarState
                 feeCfg
                 slotCfg
    where
        servicePort = baseUrlPort (coerce baseUrl)
        warpSettings = Warp.defaultSettings & Warp.setPort servicePort & Warp.setBeforeMainLoop (available availability)

        buildEnv url settings = liftIO
            $ newManager settings >>= \mgr -> pure $ mkClientEnv mgr url
