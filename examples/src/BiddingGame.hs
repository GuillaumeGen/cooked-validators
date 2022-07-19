{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# OPTIONS_GHC -fno-ignore-interface-pragmas #-}
{-# OPTIONS_GHC -fno-omit-interface-pragmas #-}
{-# OPTIONS_GHC -fno-specialise #-}

-- | This module implements a bidding game.
--
-- Every game has a deadline for bids, a deadline for collecting the
-- bids, and a deadline for publishing the game results.
--
-- The expected flow is as follows:
--
-- 1. Operator starts a bidding game
-- 2. Players can place bids until the bidding deadline expires
-- 3. The operator collects the bids after the bidding deadline
--    and before the bid-collecting deadline.
-- 4. The operator publishes the game result after the bid-collecting
--    deadline and before the publishing deadline, and it distributes
--    the money among the winners
-- 5. Players are able to get their money back if the operator
--    does not publish the game results before the publishing
--    deadline.
--
-- The operator can only close the game once. In particular, she
-- shouldn't be able to close the game more than once with
-- different sets of bids.
--
-- Bids should be possible to do in parallel. Note that this
-- requirement makes impossible:
-- * to guarantee that the operator doesn't leave any bids unconsumed.
-- * to stop bidders from bidding more than once.
--
-- The operator must collect the bids ahead of knowing the result
-- of the game. Otherwise, she could chose to only collect the bids of
-- the losers and never pay any money back to the winners.
--
module BiddingGame where

import Data.Aeson (FromJSON, ToJSON)
import GHC.Generics (Generic)
import qualified Ledger
import qualified Ledger.Ada as Ada
import qualified Ledger.Typed.Scripts as Scripts
import qualified Ledger.Value as Value (geq)
import Plutus.V1.Ledger.Api (Datum (Datum))
import Plutus.V1.Ledger.Contexts (ScriptContext (..))
import qualified PlutusTx
import PlutusTx.Prelude hiding (Applicative (..))
import Schema (ToSchema)
import qualified Prelude as Haskell


-- * On-chain validation
--
-- $contract-flow
-- Contract flow
--
-- * The operator creates an output to the script with datum @GameStart@
-- * The bidders pay to the script with datum @Bid GameResult@
-- * The operator collects the bids and pays to the script with all of
--   the collected money and datum @CollectedBids _bids@.
-- * The operator publishes the result and pays to the winners.
--
-- If the operator does not collect, players reclaim their individual bids.
-- If the operator does not publish the result, anyone can return the
-- collected bids to all players.

data BidParams = BidParams
  { biddingDeadline :: Ledger.POSIXTime
  , collectionDeadline :: Ledger.POSIXTime
  , publishingDeadline :: Ledger.POSIXTime
  , minimumBid :: Ada.Ada
  , description :: BuiltinByteString
  , operator :: Ledger.PubKeyHash
  }
  deriving stock (Haskell.Show, Haskell.Eq, Generic)
  deriving anyclass (ToJSON, FromJSON, ToSchema)

type GameResult = Bool

-- | [(bidder, bet result, amount)]
type Bids = [(Ledger.PubKeyHash, GameResult, Ada.Ada)]

data BidDatum
  = GameStart BidParams
  | -- | Contains the identity of the bidder and the bet result
    Bid Ledger.PubKeyHash GameResult
  | -- | Contains the bidders, with duplicates if they bid more than once.
    CollectedBids Bids
  deriving stock (Haskell.Show, Haskell.Eq, Generic)

data BidRedeemer
  = BidCollection Bids
  | GameClose GameResult
  | BidReclaim

minLovelace :: Integer
minLovelace = 2000000

validateBid
  :: BidParams -> BidDatum -> BidRedeemer -> ScriptContext -> Bool
validateBid p d0 r ctx =
    let info :: Ledger.TxInfo
        info = Ledger.scriptContextTxInfo ctx

        outputs = Ledger.txInfoOutputs info

        outputHasCollectedBids bids =
          case Ledger.findDatumHash
                 (Datum $ PlutusTx.toBuiltinData $ CollectedBids bids)
                 info
            of
            Just h -> any ((Just h ==) . Ledger.txOutDatumHash) outputs
            Nothing -> False

        bidIsInTransactionBids bidder gr bids =
          case findInputWithDatum (Bid bidder gr) info of
            Just i ->
              let betValue = Ada.fromValue $ Ledger.txOutValue $ Ledger.txInInfoResolved i
               in any (\(b, gr', v) -> bidder == b && gr == gr' && betValue == v) bids
            Nothing ->
              False

     in case r of
      BidCollection bids ->
        case d0 of
          GameStart _p ->
             traceIfFalse "only the operator can collect the output of gamestart"
               (elem (operator p) $ Ledger.txInfoSignatories info)
          Bid bidder gr ->
               traceIfFalse "collection deadline expired"
                 (Ledger.to (collectionDeadline p) `Ledger.contains` Ledger.txInfoValidRange info)
            && traceIfFalse "the transaction must consume an output with datum GameStart"
                 (isJust $ findInputWithDatum (GameStart p) info)
            && traceIfFalse "there must be a single output containing the list of bidders and the total money that each one bet"
                 (outputHasCollectedBids bids)
            && traceIfFalse "there must not be other outputs"
                 (length outputs == 1)
            && traceIfFalse "the bid of this output must be included in the list of bids in the transaction output"
                 (bidIsInTransactionBids bidder gr bids)
          _ ->
             traceIfFalse "BidCollection can only take outputs with GameStart and Bid datums" False
      GameClose _gr ->
        case d0 of
          CollectedBids _bids ->
               traceIfFalse "publication deadline expired"
                 (Ledger.to (publishingDeadline p) `Ledger.contains` Ledger.txInfoValidRange info)
            && traceIfFalse "bidding deadline hasn't expired"
                 (Ledger.to (biddingDeadline p) `Ledger.contains` Ledger.txInfoValidRange info)
            && traceIfFalse "the transaction must consume the output of exactly one bid collecting transaction" False
            && traceIfFalse "the operator must earns a commission" False
            && traceIfFalse "all winners must earn in proportion to what they bid" False
            && traceIfFalse "nobody else is allowed to earn anything" False
            && traceIfFalse "the transaction must be signed by the operator (so we can trust the result)" False
          _ ->
            traceIfFalse "GameClose can only take an output with datum BidCollection" False

      BidReclaim ->
        case d0 of
          Bid _bidder _gr ->
               traceIfFalse "publication deadline must have expired"
                 (Ledger.to (publishingDeadline p) `Ledger.contains` Ledger.txInfoValidRange info)
            && traceIfFalse "the transaction must pay to the bidder" False
          CollectedBids _bids ->
               traceIfFalse "publication deadline must have expired"
                 (Ledger.to (publishingDeadline p) `Ledger.contains` Ledger.txInfoValidRange info)
            && traceIfFalse "the transaction must pay to all players" False
          _ ->
             traceIfFalse "BidReclaim can only take outputs with Bid and BidCollection datums" False
  where
    findInputWithDatum :: BidDatum -> Ledger.TxInfo -> Maybe Ledger.TxInInfo
    findInputWithDatum d info =
      case Ledger.findDatumHash
             (Datum $ PlutusTx.toBuiltinData d)
             info
        of
        Just h ->
          let hasDatum =
                (Just h ==) . Ledger.txOutDatumHash . Ledger.txInInfoResolved
           in find hasDatum (Ledger.txInfoInputs info)
        Nothing -> Nothing

-- Plutus boilerplate

data BiddingGame

PlutusTx.makeLift ''BidParams
PlutusTx.unstableMakeIsData ''BidDatum
PlutusTx.unstableMakeIsData ''BidParams
PlutusTx.unstableMakeIsData ''BidRedeemer

instance Scripts.ValidatorTypes BiddingGame where
  type RedeemerType BiddingGame = BidRedeemer
  type DatumType BiddingGame = BidDatum

bidValidator :: BidParams -> Scripts.TypedValidator BiddingGame
bidValidator p =
  Scripts.mkTypedValidator @BiddingGame
    ($$(PlutusTx.compile [||validateBid||]) `PlutusTx.applyCode` PlutusTx.liftCode p)
    $$(PlutusTx.compile [||wrap||])
  where
    wrap = Scripts.mkUntypedValidator @BidDatum @BidRedeemer
