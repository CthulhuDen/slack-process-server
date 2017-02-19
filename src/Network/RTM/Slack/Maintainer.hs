module Network.RTM.Slack.Maintainer
    ( withMaintainedState
    , maintainState
    , SlackHandler
    , SlackCallback
    , SlackState (..)
    , slackSelf
    , slackTeam
    , slackUsers
    , slackChannels
    , slackGroups
    , slackIMs
    , slackBots
    , stateFromSession
    ) where

import ClassyPrelude
import Control.Distributed.Process
import Control.Distributed.Process.Internal.Types
import Network.RTM.Slack.State
import Network.RTM.Slack.State.Update
import qualified Web.Slack.Handle as S
import Control.Monad.State

data FullState = FullState { stateHandle :: S.SlackHandle
                           , stateContents :: SlackState
                           }

initFromHandle :: S.SlackHandle -> FullState
initFromHandle h = FullState h . stateFromSession $ S.getSession h

type Maintainer = StateT FullState Process

getHandle :: Maintainer S.SlackHandle
getHandle = gets stateHandle

getState :: Maintainer SlackState
getState = gets stateContents

updateState :: S.Event -> Maintainer ()
updateState e = modify $ \(FullState h s) -> FullState h $ update e s

type SlackHandler = S.Event -> S.SlackHandle -> SlackState -> Process ()
type SlackCallback = S.Event -> SlackState -> Process ()

withMaintainedState :: Text -> SlackHandler -> Process ()
withMaintainedState t c = Process $ ReaderT $ \p -> S.withSlackHandle (S.SlackConfig $ unpack t)
                                                        $ \h -> runReaderT (unProcess $ maintainState h $ flip c h) p

maintainState :: S.SlackHandle -> SlackCallback -> Process ()
maintainState h c = void . runStateT loop $ initFromHandle h
  where
    loop :: Maintainer ()
    loop = forever $ do
        e <- getHandle >>= liftIO . S.getNextEvent
        void $ updateState e
        getState >>= void . lift . spawnLocal . c e
