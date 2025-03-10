{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Ormolu.Printer.Meat.Declaration.Value
  ( p_valDecl
  , p_pat
  )
where

import Bag (bagToList)
import BasicTypes
import Control.Monad
import Data.Data
import Data.List (sortOn)
import Data.String (fromString)
import FastString as GHC
import GHC
import Ormolu.Printer.Combinators
import Ormolu.Printer.Meat.Common
import Ormolu.Printer.Meat.Declaration.Signature
import Ormolu.Printer.Meat.Type
import Ormolu.Utils
import Outputable (Outputable (..))
import SrcLoc (isOneLineSpan)
import qualified Data.List.NonEmpty as NE
import qualified Data.Text as T

data MatchGroupStyle
  = Function (Located RdrName)
  | PatternBind
  | Case
  | Lambda
  | LambdaCase

data GroupStyle
  = EqualSign
  | RightArrow

-- | Expression placement. This marks the places where expressions that
-- implement handing forms may use them.

data Placement
  = Normal                      -- ^ Multi-line layout should cause
                                -- insertion of a newline and indentation
                                -- bump
  | Hanging                     -- ^ Expressions that have hanging form
                                -- should use it and avoid bumping one level
                                -- of indentation

p_valDecl :: HsBindLR GhcPs GhcPs -> R ()
p_valDecl = line . p_valDecl'

p_valDecl' :: HsBindLR GhcPs GhcPs -> R ()
p_valDecl' = \case
  FunBind NoExt funId funMatches _ _ -> p_funBind funId funMatches
  PatBind NoExt pat grhss _ -> p_match PatternBind [pat] grhss
  VarBind {} -> notImplemented "VarBinds" -- introduced by the type checker
  AbsBinds {} -> notImplemented "AbsBinds" -- introduced by the type checker
  PatSynBind NoExt psb -> p_patSynBind psb
  XHsBindsLR NoExt -> notImplemented "XHsBindsLR"

p_funBind
  :: Located RdrName
  -> MatchGroup GhcPs (LHsExpr GhcPs)
  -> R ()
p_funBind name mgroup =
  p_matchGroup (Function name) mgroup

p_matchGroup
  :: MatchGroupStyle
  -> MatchGroup GhcPs (LHsExpr GhcPs)
  -> R ()
p_matchGroup style MG {..} =
  locatedVia Nothing mg_alts $
    newlineSep (located' (\Match {..} -> p_match style m_pats m_grhss))
p_matchGroup _ (XMatchGroup NoExt) = notImplemented "XMatchGroup"

p_match
  :: MatchGroupStyle
  -> [LPat GhcPs]
  -> GRHSs GhcPs (LHsExpr GhcPs)
  -> R ()
p_match style m_pats m_grhss = do
  case style of
    Function name -> p_rdrName name
    _ -> return ()
  -- NOTE Normally, since patterns may be placed in a multi-line layout, it
  -- is necessary to bump indentation for the pattern group so it's more
  -- indented than function name. This in turn means that indentation for
  -- the body should also be bumped. Normally this would mean that bodies
  -- would start with two indentation steps applied, which is ugly, so we
  -- need to be a bit more clever here and bump indentation level only when
  -- pattern group is multiline.
  inci' <- case NE.nonEmpty m_pats of
    Nothing -> return id
    Just ne_pats -> do
      let combinedSpans = combineSrcSpans' $
            getSpan <$> ne_pats
          inci' = if isOneLineSpan combinedSpans
            then id
            else inci
      switchLayout combinedSpans $ do
        case style of
          Function _ -> breakpoint
          PatternBind -> return ()
          Case -> return ()
          Lambda -> txt "\\"
          LambdaCase -> return ()
        let wrapper = case style of
              Function _ -> inci'
              _ -> id
        wrapper (velt' (located' p_pat <$> m_pats))
      return inci'
  inci' $ do
    let GRHSs {..} = m_grhss
        hasGuards = withGuards grhssGRHSs
    unless (length grhssGRHSs > 1) $ do
      case style of
        Function _ -> txt " ="
        PatternBind -> txt " ="
        Case -> unless hasGuards (txt " ->")
        _ -> txt " ->"
    let combinedSpans = combineSrcSpans' $
          getGRHSSpan . unL <$> NE.fromList grhssGRHSs
        p_body = do
          let groupStyle =
                case style of
                  Case ->
                    if hasGuards
                      then RightArrow
                      else EqualSign
                  _ -> EqualSign
          newlineSep (located' (p_grhs groupStyle)) grhssGRHSs
          unless (GHC.isEmptyLocalBindsPR (unL grhssLocalBinds)) $ do
            newline
            line (txt "where")
            inci (located grhssLocalBinds p_hsLocalBinds)
        placement = blockPlacement grhssGRHSs
    case style of
      Lambda -> placeHanging placement $
        switchLayout combinedSpans p_body
      _ -> switchLayout combinedSpans $
        placeHanging placement p_body

p_grhs :: GroupStyle -> GRHS GhcPs (LHsExpr GhcPs) -> R ()
p_grhs style (GRHS NoExt guards body) =
  case guards of
    [] -> p_body
    xs -> do
      txt "| "
      velt $ withSep comma (located' p_stmt) xs
      space
      txt $ case style of
        EqualSign -> "="
        RightArrow -> "->"
      breakpoint
      inci p_body
  where
    p_body = located body p_hsExpr
p_grhs _ (XGRHS NoExt) = notImplemented "XGRHS"

p_stmt :: Stmt GhcPs (LHsExpr GhcPs) -> R ()
p_stmt = \case
  LastStmt NoExt _ _ _ ->
    notImplemented "LastStmt" -- only available after renamer
  BindStmt NoExt l f _ _ -> do
    located l p_pat
    space
    txt "<-"
    breakpoint
    inci (located f p_hsExpr)
  ApplicativeStmt {} -> notImplemented "ApplicativeStmt"
  BodyStmt NoExt body _ _ -> located body p_hsExpr
  LetStmt NoExt binds -> do
    txt "let "
    sitcc $ located binds p_hsLocalBinds
  ParStmt {} -> notImplemented "ParStmt"
  TransStmt {} -> notImplemented "TransStmt"
  RecStmt {} -> notImplemented "RecStmt"
  XStmtLR {} -> notImplemented "XStmtLR"

p_hsLocalBinds :: HsLocalBindsLR GhcPs GhcPs -> R ()
p_hsLocalBinds = \case
  HsValBinds NoExt (ValBinds NoExt bag lsigs) -> do
    let ssStart = either
          (srcSpanStart . getSpan)
          (srcSpanStart . getSpan)
        items =
          (Left <$> bagToList bag) ++ (Right <$> lsigs)
        p_item (Left x) = located x p_valDecl'
        p_item (Right x) = located x p_sigDecl'
    newlineSep p_item (sortOn ssStart items)
  HsValBinds NoExt _ -> notImplemented "HsValBinds"
  HsIPBinds NoExt _ -> notImplemented "HsIPBinds"
  EmptyLocalBinds NoExt -> return ()
  XHsLocalBindsLR _ -> notImplemented "XHsLocalBindsLR"

p_hsRecField
  :: (Data id, Outputable id)
  => HsRecField' id (LHsExpr GhcPs)
  -> R ()
p_hsRecField = \HsRecField {..} -> do
  located hsRecFieldLbl atom
  unless hsRecPun $ do
    txt " = "
    located hsRecFieldArg p_hsExpr

p_hsTupArg :: HsTupArg GhcPs -> R ()
p_hsTupArg = \case
  Present NoExt x -> located x p_hsExpr
  Missing NoExt -> pure ()
  XTupArg {} -> notImplemented "XTupArg"

p_hsExpr :: HsExpr GhcPs -> R ()
p_hsExpr = \case
  HsVar NoExt name -> p_rdrName name
  HsUnboundVar NoExt _ -> notImplemented "HsUnboundVar"
  HsConLikeOut NoExt _ -> notImplemented "HsConLikeOut"
  HsRecFld NoExt x ->
    case x of
      Unambiguous NoExt name -> p_rdrName name
      Ambiguous NoExt name -> p_rdrName name
      XAmbiguousFieldOcc NoExt -> notImplemented "XAmbiguousFieldOcc"
  HsOverLabel NoExt _ v -> do
    txt "#"
    atom v
  HsIPVar NoExt (HsIPName name) -> do
    txt "?"
    atom name
  HsOverLit NoExt v -> atom (ol_val v)
  HsLit NoExt lit -> atom lit
  HsLam NoExt mgroup ->
    p_matchGroup Lambda mgroup
  HsLamCase NoExt mgroup -> do
    txt "\\case"
    newline
    inci (p_matchGroup LambdaCase mgroup)
  HsApp NoExt f x -> do
    located f p_hsExpr
    breakpoint
    inci (located x p_hsExpr)
  HsAppType a e -> do
    located e p_hsExpr
    breakpoint
    inci $ do
      txt "@"
      located (hswc_body a) p_hsType
  OpApp NoExt x op y -> do
    located x p_hsExpr
    space
    located op p_hsExpr
    placeHanging (exprPlacement (unL y)) $
      located y p_hsExpr
  NegApp NoExt e _ -> do
    txt "-"
    located e p_hsExpr
  HsPar NoExt e -> parens (located e p_hsExpr)
  SectionL NoExt x op -> do
    located x p_hsExpr
    breakpoint
    inci (located op p_hsExpr)
  SectionR NoExt op x -> do
    located op p_hsExpr
    breakpoint
    inci (located x p_hsExpr)
  ExplicitTuple NoExt args boxity -> do
    let isSection = any (isMissing . unL) args
        isMissing = \case
          Missing NoExt -> True
          _ -> False
    let parens' =
          case boxity of
            Boxed -> parens
            Unboxed -> parensHash
    parens' $ if isSection
      then sequence_ (withSep (txt ",") (located' p_hsTupArg) args)
      else velt (withSep comma (located' p_hsTupArg) args)
  ExplicitSum NoExt tag arity e -> do
    let before = tag - 1
        after = arity - before - 1
        args = replicate before Nothing <> [Just e] <> replicate after Nothing
        f (x,i) = do
          let isFirst = i == 0
              isLast = i == arity - 1
          case x of
            Nothing ->
              unless (isFirst || isLast) space
            Just l -> do
              unless isFirst space
              located l p_hsExpr
              unless isLast space
    parensHash $ sequence_ (withSep (txt "|") f (zip args [0..]))
  HsCase NoExt e mgroup -> do
    txt "case "
    located e p_hsExpr
    txt " of"
    breakpoint
    inci (p_matchGroup Case mgroup)
  HsIf NoExt _ if' then' else' -> do
    txt "if "
    located if' p_hsExpr
    breakpoint
    txt "then"
    located then' $ \x -> do
      breakpoint
      inci (p_hsExpr x)
    breakpoint
    txt "else"
    located else' $ \x -> do
      breakpoint
      inci (p_hsExpr x)
  HsMultiIf NoExt guards -> do
    txt "if "
    sitcc $ newlineSep (located' (p_grhs RightArrow)) guards
  HsLet NoExt localBinds e -> do
    txt "let "
    sitcc (located localBinds p_hsLocalBinds)
    breakpoint
    txt "in "
    sitcc (located e p_hsExpr)
  HsDo NoExt ctx es -> do
    case ctx of
      DoExpr -> txt "do"
      MDoExpr -> txt "mdo"
      _ -> notImplemented "certain kinds of do notation"
    newline
    inci $ located es (newlineSep (located' (sitcc . p_stmt)))
  ExplicitList _ _ xs ->
    brackets $ velt (withSep comma (located' p_hsExpr) xs)
  RecordCon {..} -> do
    located rcon_con_name atom
    breakpoint
    let HsRecFields {..} = rcon_flds
        fields = located' p_hsRecField <$> rec_flds
        dotdot =
          case rec_dotdot of
            Just {} -> [txt ".."]
            Nothing -> []
    inci $ braces $ velt (withSep comma id (fields <> dotdot))
  RecordUpd {..} -> do
    located rupd_expr p_hsExpr
    breakpoint
    inci $ braces $ velt (withSep comma (located' p_hsRecField) rupd_flds)
  ExprWithTySig affix x -> do
    located x p_hsExpr
    breakpoint
    inci $ do
      txt ":: "
      let HsWC {..} = affix
          HsIB {..} = hswc_body
      located hsib_body p_hsType
  ArithSeq NoExt _ x -> do
    let breakpoint' = vlayout (return ()) newline
    case x of
      From from -> brackets $ do
        located from p_hsExpr
        breakpoint'
        txt ".."
      FromThen from next -> brackets $ do
        velt (withSep comma (located' p_hsExpr) [from, next])
        breakpoint'
        txt ".."
      FromTo from to -> brackets $ do
        located from p_hsExpr
        breakpoint'
        txt ".. "
        located to p_hsExpr
      FromThenTo from next to -> brackets $ do
        velt (withSep comma (located' p_hsExpr) [from, next])
        breakpoint'
        txt ".. "
        located to p_hsExpr
  HsSCC NoExt _ name x -> do
    txt "{-# SCC "
    atom name
    txt " #-}"
    breakpoint
    located x p_hsExpr
  HsCoreAnn NoExt _ value x -> do
    txt "{-# CORE "
    atom value
    txt " #-}"
    breakpoint
    located x p_hsExpr
  HsBracket {} -> notImplemented "HsBracket"
  HsRnBracketOut {} -> notImplemented "HsRnBracketOut"
  HsTcBracketOut {} -> notImplemented "HsTcBracketOut"
  HsSpliceE NoExt splice -> p_hsSplice splice
  HsProc {} -> notImplemented "HsProc"
  HsStatic _  e -> do
    txt "static"
    breakpoint
    inci (located e p_hsExpr)
  HsArrApp {} -> notImplemented "HsArrApp"
  HsArrForm {} -> notImplemented "HsArrForm"
  HsTick {} -> notImplemented "HsTick"
  HsBinTick {} -> notImplemented "HsBinTick"
  HsTickPragma {} -> notImplemented "HsTickPragma"
  EWildPat NoExt -> txt "_"
  EAsPat {} -> notImplemented "EAsPat"
  EViewPat {} -> notImplemented "EViewPat"
  ELazyPat {} -> notImplemented "ELazyPat"
  HsWrap {} -> notImplemented "HsWrap"
  XExpr {} -> notImplemented "XExpr"

p_patSynBind :: PatSynBind GhcPs GhcPs -> R ()
p_patSynBind PSB {..} = do
  txt "pattern "
  case psb_dir of
    Unidirectional -> do
      p_rdrName psb_id
      space
      p_patSynDetails psb_args
      txt " <-"
      breakpoint
      inci (located psb_def p_pat)
    ImplicitBidirectional -> do
      p_rdrName psb_id
      space
      p_patSynDetails psb_args
      txt " ="
      breakpoint
      located psb_def p_pat
    ExplicitBidirectional mgroup -> do
      p_rdrName psb_id
      space
      p_patSynDetails psb_args
      txt " <-"
      breakpoint
      inci (located psb_def p_pat)
      newline
      inci $ do
        line (txt "where")
        inci (p_matchGroup (Function psb_id) mgroup)
p_patSynBind (XPatSynBind NoExt) = notImplemented "XPatSynBind"

p_patSynDetails :: HsPatSynDetails (Located RdrName) -> R ()
p_patSynDetails = \case
  PrefixCon xs ->
    velt' (p_rdrName <$> xs)
  RecCon xs ->
    velt' (p_rdrName . recordPatSynPatVar <$> xs)
  InfixCon _ _ -> notImplemented "InfixCon"

p_pat :: Pat GhcPs -> R ()
p_pat = \case
  WildPat NoExt -> txt "_"
  VarPat NoExt name -> p_rdrName name
  LazyPat NoExt pat -> do
    txt "~"
    located pat p_pat
  AsPat NoExt name pat -> do
    p_rdrName name
    txt "@"
    located pat p_pat
  ParPat NoExt pat ->
    located pat (parens . p_pat)
  BangPat NoExt pat -> do
    txt "!"
    located pat p_pat
  ListPat NoExt pats -> do
    brackets $ velt (withSep comma (located' p_pat) pats)
  TuplePat NoExt pats boxing -> do
    let f =
          case boxing of
            Boxed -> parens
            Unboxed -> parensHash
    f $ velt (withSep comma (located' p_pat) pats)
  SumPat NoExt pat _ _ -> do
    -- XXX I'm not sure about this one.
    located pat p_pat
  ConPatIn pat details ->
    case details of
      PrefixCon xs -> sitcc $ do
        p_rdrName pat
        unless (null xs) $ do
          breakpoint
          inci $ velt' (located' p_pat <$> xs)
      RecCon (HsRecFields fields dotdot) -> do
        p_rdrName pat
        breakpoint
        let f = \case
              Nothing -> txt ".."
              Just x -> located x p_pat_hsRecField
        inci . braces . velt . withSep comma f $ case dotdot of
          Nothing -> Just <$> fields
          Just n -> (Just <$> take n fields) ++ [Nothing]
      InfixCon x y -> do
        located x p_pat
        space
        p_rdrName pat
        breakpoint
        inci (located y p_pat)
  ConPatOut {} -> notImplemented "ConPatOut"
  ViewPat NoExt expr pat -> sitcc $ do
    located expr p_hsExpr
    txt " ->"
    breakpoint
    inci (located pat p_pat)
  SplicePat NoExt splice -> p_hsSplice splice
  LitPat NoExt p -> atom p
  NPat NoExt v _ _ -> located v (atom . ol_val)
  NPlusKPat {} -> notImplemented "NPlusKPat"
  SigPat hswc pat -> do
    located pat p_pat
    p_typeAscription hswc
  CoPat {} -> notImplemented "CoPat"
  XPat NoExt -> notImplemented "XPat"

p_pat_hsRecField :: HsRecField' (FieldOcc GhcPs) (LPat GhcPs) -> R ()
p_pat_hsRecField HsRecField {..} = do
  located hsRecFieldLbl $ \x ->
    p_rdrName (rdrNameFieldOcc x)
  unless hsRecPun $ do
    txt " ="
    breakpoint
    inci (located hsRecFieldArg p_pat)

p_hsSplice :: HsSplice GhcPs -> R ()
p_hsSplice = \case
  HsTypedSplice {} -> notImplemented "HsTypedSplice"
  HsUntypedSplice {} -> notImplemented "HsUntypedSplice"
  HsQuasiQuote NoExt _ quoterName srcSpan str -> do
    let locatedQuoterName = L srcSpan quoterName
    p_quasiQuote locatedQuoterName $ do
      let p x = unless (T.null x) (txt x)
      newlineSep (p . T.strip) (T.lines . T.strip . fromString . GHC.unpackFS $ str)
  HsSpliced {} -> notImplemented "HsSpliced"
  XSplice {} -> notImplemented "XSplice"

p_quasiQuote :: Located RdrName -> R () -> R ()
p_quasiQuote quoter m = do
  txt "["
  p_rdrName quoter
  txt "|"
  let breakpoint' = vlayout (return ()) newline
  breakpoint'
  inci m
  breakpoint'
  txt "|]"

----------------------------------------------------------------------------
-- Helpers

getGRHSSpan :: GRHS GhcPs (LHsExpr GhcPs) -> SrcSpan
getGRHSSpan (GRHS NoExt _ body) = getSpan body
getGRHSSpan (XGRHS NoExt) = notImplemented "XGRHS"

-- | Place a thing that may have a hanging form. This function handles how
-- to separate it from preceding expressions and whether to bump indentation
-- depending on what sort of expression we have.

placeHanging :: Placement -> R () -> R ()
placeHanging placement m = do
  case placement of
    Hanging -> do
      space
      m
    Normal -> do
      breakpoint
      inci m

-- | Check if given block contains single expression which has a hanging
-- form.

blockPlacement :: [LGRHS GhcPs (LHsExpr GhcPs)] -> Placement
blockPlacement [(L _ (GRHS NoExt _ (L _ e)))] = exprPlacement e
blockPlacement _ = Normal

-- | Check if given expression has hinging a form.

exprPlacement :: HsExpr GhcPs -> Placement
exprPlacement = \case
  HsLam NoExt _ -> Hanging
  HsLamCase NoExt _ -> Hanging
  HsCase NoExt _ _ -> Hanging
  HsDo NoExt _ _ -> Hanging
  RecordCon NoExt _ _ -> Hanging
  _ -> Normal

withGuards :: [LGRHS GhcPs (LHsExpr GhcPs)] -> Bool
withGuards = any (checkOne . unL)
  where
    checkOne :: GRHS GhcPs (LHsExpr GhcPs) -> Bool
    checkOne (GRHS NoExt [] _) = False
    checkOne _ = True
