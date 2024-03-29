module Nuko.Syntax.Error (
  SyntaxError(..),
  Case(..),
  getErrorSite,
) where

import Relude

import Nuko.Report.Range        (HasPosition (..), Pos, Range, Ranged (..),
                                 oneColRange)
import Nuko.Report.Text         (Annotation (..), Color (..), Mode (..),
                                 Piece (..), PrettyDiagnostic (..),
                                 mkBasicDiagnostic)
import Nuko.Syntax.Lexer.Tokens (Token)

data Case = UpperCase | LowerCase
  deriving Show

data SyntaxError
  = UnexpectedStr Range
  | UnfinishedStr Pos
  | UnexpectedToken (Ranged Token)
  | AssignInEndOfBlock Range
  | WrongUsageOfCase Case Range
  deriving Show

errorCode :: SyntaxError -> Int
errorCode = \case
  UnexpectedStr {}      -> 1
  UnfinishedStr {}      -> 2
  UnexpectedToken {}    -> 3
  AssignInEndOfBlock {} -> 4
  WrongUsageOfCase {}   -> 5

getErrorSite :: SyntaxError -> Range
getErrorSite = \case
  UnexpectedStr r      -> r
  UnfinishedStr r      -> oneColRange r
  UnexpectedToken r    -> getPos r
  AssignInEndOfBlock r -> r
  WrongUsageOfCase _ r -> r

errorTitle :: SyntaxError -> Mode
errorTitle = \case
  UnexpectedStr r -> Words [Raw "Unexpected token", Marked Fst (show r)]
  UnfinishedStr _ -> Words [Raw "Unfinished string"]
  UnexpectedToken r -> Words [Raw "Unexpected token", Marked Fst (show r)]
  AssignInEndOfBlock _ -> Words [Raw "You cannot assign a new variable in the end of a block!"]
  WrongUsageOfCase UpperCase _ -> Words [Raw "The identifier should be upper cased"]
  WrongUsageOfCase LowerCase _ -> Words [Raw "The identifier should be lower cased"]

instance PrettyDiagnostic SyntaxError where
  prettyDiagnostic cause =
    let (Words title) = errorTitle cause in
    mkBasicDiagnostic (errorCode cause) title [Ann Fst (Words [Raw "Here!"]) (getErrorSite cause)]
