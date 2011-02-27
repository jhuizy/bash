{-# LANGUAGE OverloadedStrings
           , StandaloneDeriving
           , RecordWildCards
           , NamedFieldPuns
           , NoMonomorphismRestriction
           , GeneralizedNewtypeDeriving
           , UndecidableInstances
  #-}
{-| Pretty printer for Bash.
 -}
module Language.Bash.PrettyPrinter where

import Data.Word (Word8)
import Data.ByteString.Char8
import Data.Binary.Builder (Builder)
import Prelude hiding (concat, length, replicate, lines, drop, null)
import Control.Monad.State.Strict

import qualified Text.ShellEscape as Esc

import Language.Bash.Syntax
import Language.Bash.PrettyPrinter.State


bytes                       ::  (PP t) => t -> ByteString
bytes                        =  renderBytes (nlCol 0) . pp

builder                     ::  (PP t) => t -> Builder
builder                      =  render (nlCol 0) . pp

bytes_state                  =  renderBytes (nlCol 0)

class PP t where
  pp                        ::  t -> State PPState ()
instance PP Identifier where
  pp (Identifier b)          =  word b
instance PP SpecialVar where
  pp                         =  word . specialVarBytes
instance PP Expression where
  pp (Literal lit)           =  word (Esc.bytes lit)
  pp Asterisk                =  word "*"
  pp QuestionMark            =  word "?"
  pp (ReadVar var)           =  (word . quote . ('$' `cons`) . identpart) var
  pp (ReadVarSafe var)       =  (word . quote . braces0 . identpart) var
  pp (ReadArray ident expr)  =  (word . braces)
                                (bytes ident `append` brackets (bytes expr))
  pp (ReadArraySafe ident expr) = (word . braces0)
                                  (bytes ident `append` brackets (bytes expr))
  -- Examples that all work for nasty arguments containing brackets:
  --   echo "${array[$1]}"
  --   echo "${array["$1"]}"
  --   echo "${array["$1""$2"]}"
  -- Looks like we can get away with murder here.
  pp (ARGVElements)          =  word "\"$@\""
  pp (ARGVLength)            =  word "$#"
  pp (Elements ident)        =  (word . quote . braces)
                                (bytes ident `append` "[@]")
  pp (Length ident)          =  (word . quote . braces)
                                ('#' `cons` bytes ident)
  pp (ArrayLength ident)     =  (word . quote . braces)
                                ('#' `cons` bytes ident `append` "[@]")
  pp (Concat expr0 expr1)    =  wordcat [bytes expr0, bytes expr1]
instance PP FileDescriptor where
  pp (FileDescriptor w)      =  (word . pack . show) w
instance PP ((), Statement ()) where
  pp                         =  pp . snd
instance (PP (t, Statement t)) => PP (Annotated t) where
  pp (Annotated t stmt)      =  pp (t, stmt)
instance PP (Statement ()) where
  pp term                    =  case term of
    SimpleCommand cmd args  ->  do hang (bytes cmd)
                                   mapM_ (breakline . bytes) args
                                   outdent
    NoOp msg | null msg     ->  word ":"
             | otherwise    ->  word ":" >> (word . Esc.bytes . Esc.bash) msg
    Bang t                  ->  hang "!"      >> binGrp t >> outdent
    AndAnd t t'             ->  binGrp t >> word "&&" >> nl >> binGrp t'
    OrOr t t'               ->  binGrp t >> word "||" >> nl >> binGrp t'
    Pipe t t'               ->  binGrp t >> word "|"  >> nl >> binGrp t'
    Sequence t t'           ->  pp t          >> nl        >> pp t'
    Background t t'         ->  binGrp t >> word "&"  >> nl >> pp t'
    Group t                 ->  curlyOpen >> pp t     >> curlyClose >> outdent
    Subshell t              ->  roundOpen >> pp t     >> roundClose >> outdent
    Function ident t        ->  do wordcat ["function ", bytes ident]
                                   inword " {" >> pp t >> outword "}"
    IfThen t t'             ->  do hang "if" >> pp t   >> outdent   >> nl
                                   inword "then" >> pp t' >> outword "fi"
    IfThenElse t t' t''     ->  do hang "if" >> pp t   >> outdent   >> nl
                                   inword "then"       >> pp t'     >> outdent
                                   nl
                                   inword "else"       >> pp t''
                                   outword "fi"
    For var vals t          ->  do hang (concat ["for ", bytes var, " in"])
                                   mapM_ (breakline . bytes) vals 
                                   outdent >> nl
                                   inword "do" >> pp t >> outword "done"
    Case expr cases         ->  do word "case" >> pp expr >> inword "in"
                                   mapM_ case_clause cases
                                   outword "esac"
    While t t'              ->  do hang "while" >> pp t >> outdent >> nl
                                   inword "do" >> pp t' >> outword "done"
    Until t t'              ->  do hang "until" >> pp t >> outdent >> nl
                                   inword "do" >> pp t' >> outword "done"
--  BraceBrace _            ->  error "[[ ]]"
    VarAssign var val       ->  pp var >> word "=" >> pp val
    DictDecl var pairs      ->  do wordcat ["declare -A ", bytes var, "=("]
                                   nl >> mapM_ arrayset pairs
                                   nl >> word ")"
    DictUpdate var key val  ->  do pp var >> word "["
                                   pp key >> word "]="
                                   pp val
    DictAssign var pairs    ->  do pp var >> word "=(" >> nl
                                   mapM_ arrayset pairs >> word ")"
    Redirect stmt d fd t    ->  do redirectGrp stmt
                                   word (render_redirect d fd t)

arrayset (key, val) = word "[" >> pp key >> word "]=" >> pp val >> nl

case_clause (ptrn, stmt)     =  do hang (bytes ptrn `append` ") ")
                                   pp stmt >> word ";;" >> outdent >> nl

render_redirect direction fd target =
  concat [ bytes fd, case direction of In     -> "<"
                                       Out    -> ">"
                                       Append -> ">>"
                   , case target of Left expr -> bytes expr
                                    Right fd' -> '&' `cons` bytes fd' ]

quote b                      =  '"' `cons` b `snoc` '"'

braces b                     =  "${" `append` b `snoc` '}'

braces0 b                    =  "${" `append` b `append` ":-}"

brackets b                   =  '[' `cons` b `snoc` ']'

identpart (Left special)     =  (drop 1 . bytes) special
identpart (Right ident)      =  bytes ident

binGrp a@(Annotated _ stmt)  =  case stmt of
  Bang _                    ->  curlyOpen >> pp a >> curlyClose
  AndAnd _ _                ->  curlyOpen >> pp a >> curlyClose
  OrOr _ _                  ->  curlyOpen >> pp a >> curlyClose
  Pipe _ _                  ->  curlyOpen >> pp a >> curlyClose
  Sequence _ _              ->  curlyOpen >> pp a >> curlyClose
  Background _ _            ->  curlyOpen >> pp a >> curlyClose
  _                         ->  pp a

redirectGrp a@(Annotated _ stmt) = case stmt of
  Redirect _ _ _ _          ->  curlyOpen >> pp a >> curlyClose
  _                         ->  binGrp a

