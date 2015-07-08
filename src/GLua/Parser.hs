{-# LANGUAGE FlexibleInstances,
            TypeSynonymInstances,
            MultiParamTypeClasses,
            Rank2Types, FlexibleContexts, NoMonomorphismRestriction,
            CPP #-}

-- | Parser based on <http://www.lua.org/manual/5.2/manual.html#9>
module GLua.Parser where

import GLua.TokenTypes
import GLua.AG.AST
import qualified GLua.Lexer as Lex

import Text.ParserCombinators.UU
import Text.ParserCombinators.UU.Utils
import Text.ParserCombinators.UU.BasicInstances
import Text.ParserCombinators.UU.Derived
import qualified Data.ListLike as LL

-- | MTokens with the positions of the next MToken (used in the advance of parser)
type MTokenPos = (MToken, LineColPos)
-- | Custom parser that parses MTokens
type AParser a = forall state. (IsLocationUpdatedBy LineColPos MTokenPos, LL.ListLike state MTokenPos) => P (Str MTokenPos state LineColPos) a

-- | LineColPos is a location that can be updated by MTokens
instance IsLocationUpdatedBy LineColPos MTokenPos where
    -- advance :: LineColPos -> MToken -> LineColPos
    -- Assume the position of the next MToken
    advance pos (_, p) = p


-- | Parse Garry's mod Lua tokens to an abstract syntax tree.
-- Also returns parse errors
parseGLua :: [MToken] -> (AST, [Error LineColPos])
parseGLua mts = let (cms, ts) = splitComments mts in
                 execAParser (parseChunk cms) ts

-- | Parse a string directly into an AST
parseGLuaFromString :: String -> (AST, [Error LineColPos])
parseGLuaFromString = parseGLua . fst . Lex.execParseTokens

-- | Parse a string directly
parseFromString :: AParser a -> String -> (a, [Error LineColPos])
parseFromString p = execAParser p . fst . Lex.execParseTokens

-- | Create a parsable string from MTokens
createString :: [MToken] -> Str MTokenPos [MTokenPos] LineColPos
createString [] = createStr (LineColPos 0 0 0) []
createString mts@(MToken p _ : xs) = createStr p mtpos where
    mts' = xs ++ [last mts] -- Repeat last element of mts
    mkMtPos mt (MToken p' _) = (mt, p')
    mtpos = zipWith mkMtPos mts mts'

-- | Text.ParserCombinators.UU.Utils.execParser modified to parse MTokens
-- The first MToken might not be on the first line, so use the first MToken's position to start
execAParser :: AParser a -> [MToken] -> (a, [Error LineColPos])
execAParser p mts@[] = parse_h ((,) <$> p <*> pEnd) . createString $ mts
execAParser p mts@(m : ms) = parse_h ((,) <$> p <*> pEnd) . createString $ mts -- createStr (mpos m) $ mts


pMSatisfy :: (MToken -> Bool) -> Token -> String -> AParser MToken
pMSatisfy f t ins = fst <$> pSatisfy f' (Insertion ins (MToken ep t, ep) 5) where
    f' :: MTokenPos -> Bool
    f' (mtok, _) = f mtok

    ep = LineColPos 0 0 0

-- | Parse a single Metatoken, based on a positionless token (much like pSym)
pMTok :: Token -> AParser MToken
pMTok t = pMSatisfy isToken t $ "Token " ++ show t
    where
        isToken :: MToken -> Bool
        isToken (MToken _ tok) = t == tok

-- | Parse a list of identifiers
parseNameList :: AParser [MToken]
parseNameList = (:) <$> pName <*> pMany (pMTok Comma *> pName)

-- | Parse list of function parameters
parseParList :: AParser [MToken]
parseParList = (pMTok VarArg <<|> pName) <**> (
                    pMTok Comma <**> (
                        (\a _ c -> [c, a]) <$> pMTok VarArg <<|>
                        (\a _ c -> c : a)  <$> parseParList
                    ) `opt` (: [])
               ) `opt` []

-- | Parses the full AST
-- Its first parameter contains all comments
-- Assumes the mtokens fed to the AParser have no comments
parseChunk :: [MToken] -> AParser AST
parseChunk cms = AST cms <$> parseBlock

-- | Parse a block with an optional return value
parseBlock :: AParser Block
parseBlock = Block <$> pInterleaved (pMTok Semicolon) parseMStat <*> (parseReturn <<|> pReturn NoReturn)

parseMStat :: AParser MStat
parseMStat = MStat <$> pPos <*> parseStat
-- | Parser that is interleaved with 0 or more of the other parser
pInterleaved :: AParser a -> AParser b -> AParser [b]
pInterleaved sep q = pMany sep *> pMany (q <* pMany sep)

-- | Behemoth parser that parses either function call statements or global declaration statements
-- Big in size and complexity because prefix expressions are BITCHES
-- The problem lies in the complexity of prefix expressions:
-- hotten.totten["tenten"](tentoonstelling) -- This is a function call
-- hotten.totten["tenten"] = tentoonstelling -- This is a declaration.
-- hotten.totten["tenten"], tentoonstelling = 1, 2 -- This is also a declaration.
-- One may find an arbitrary amount of expression suffixes (indexations/calls) before 
-- finding a comma or equals sign that proves that it is a declaration.
parseCallDef :: AParser Stat
parseCallDef = (PFVar <$> pName <<|> -- Statemens begin with either a simple name or parenthesised expression
                ExprVar <$ pMTok LRound <*> parseExpression <* pMTok RRound) <**> (
                  -- We either find a call suffix, an indexation suffix or proof of a declaration (comma or equals sign)
                  -- When it's a function call, try searching for more suffixes, if that doesn't work, it's a function call.
                  -- When it's an indexation suffix, search for more suffixes or know that it's a declaration.
                  -- When it's neither, it's a declaration.
                  (pPFExprCallSuffix <**> (contSearch <<|> pReturn namedFuncCall)) <<|>
                  (pPFExprIndexSuffix <**> (contSearch <<|> varDecl indexedVarDecl)) <<|>
                  (varDecl namedVarDecl)
                )
  where
    -- Simple direct function call (funcName(...))
    namedFuncCall :: PFExprSuffix -> (ExprSuffixList -> PrefixExp) -> Stat
    namedFuncCall s pfe = AFuncCall (pfe [s])

    -- Simple direct declaration: varName, ... = 1, ...
    namedVarDecl :: [PrefixExp] -> LineColPos -> [MExpr] -> (ExprSuffixList -> PrefixExp) -> Stat
    namedVarDecl vars pos exprs pfe = let pfes = (pfe []) : vars in Def (zip pfes $ exprs ++ nils pos)

    -- Indexed variable declaration: varname[someIndex], ... = 1, ...
    -- Takes the one index it found, puts it in the suffixes and builds a declaration from that.
    indexedVarDecl :: [PrefixExp] -> LineColPos -> [MExpr] -> PFExprSuffix -> (ExprSuffixList -> PrefixExp) -> Stat
    indexedVarDecl vars pos exprs ix pfe = let pfes = (pfe [ix]) : vars in Def (zip pfes $ exprs ++ nils pos)

    -- Pad with nils (e.g "a, b = 1" => "a, b = 1, nil")
    nils :: LineColPos -> [MExpr]
    nils p = repeat (MExpr p ANil)

    -- This is where we know it's a variable declaration
    -- Takes a function that turns it into a proper Def Stat
    varDecl :: ([PrefixExp] -> LineColPos -> [MExpr] -> b) -> AParser b
    varDecl f = f <$> opt (pMTok Comma *> parseVarList) [] <*
              pMTok Equals <*>
              pPos <*>
              parseExpressionList

    -- We know that there is at least one suffix (indexation or call).
    -- Search for more suffixes and make either a call or declaration from it
    contSearch :: AParser (PFExprSuffix -> (ExprSuffixList -> PrefixExp) -> Stat)
    contSearch = (\(ss, mkStat) s pfe -> mkStat $ pfe (s : ss)) <$> searchDeeper

    searchDeeper :: AParser ([PFExprSuffix], PrefixExp -> Stat)
    searchDeeper = (pPFExprCallSuffix <**> (mergeDeeperSearch <$> searchDeeper <<|> pReturn (\s -> ([s], AFuncCall)))) <<|>
                   (pPFExprIndexSuffix <**> (mergeDeeperSearch <$> searchDeeper <<|> varDecl complexDecl))

    mergeDeeperSearch :: ([PFExprSuffix], PrefixExp -> Stat) -> PFExprSuffix -> ([PFExprSuffix], PrefixExp -> Stat)
    mergeDeeperSearch (ss, f) s = (s : ss, f)

    -- Multiple suffixes have been found, and proof has been found that this must be a declaration.
    -- Now to give all the collected suffixes and a function that creates the declaration
    complexDecl :: [PrefixExp] -> LineColPos -> [MExpr] -> PFExprSuffix -> ([PFExprSuffix], PrefixExp -> Stat)
    complexDecl vars pos exprs s = ([s], \pf -> Def (zip (pf : vars) $ exprs ++ nils pos))


-- | Parse a single statement
parseStat :: AParser Stat
parseStat = parseCallDef <<|>
            ALabel <$> parseLabel <<|>
            ABreak <$ pMTok Break <<|>
            AContinue <$ pMTok Continue <<|>
            AGoto <$ pMTok Goto <*> pName <<|>
            ADo <$ pMTok Do <*> parseBlock <* pMTok End <<|>
            AWhile <$ pMTok While <*> parseExpression <* pMTok Do <*> parseBlock <* pMTok End <<|>
            ARepeat <$ pMTok Repeat <*> parseBlock <* pMTok Until <*> parseExpression <<|>
            parseIf <<|>
            parseFor <<|>
            AFunc <$ pMTok Function <*> parseFuncName <*>
             pPacked (pMTok LRound) (pMTok RRound) parseParList <*>
             parseBlock <*
             pMTok End <<|>
            -- local function and local vars both begin with "local"
            pMTok Local <**> (
              -- local function
              (\n p b l -> ALocFunc n p b) <$
                pMTok Function <*> parseFuncName <*> pPacked (pMTok LRound) (pMTok RRound) parseParList <*>
                parseBlock <* pMTok End <<|>
              -- local variables
              (\v (p,e) l -> LocDef (zip v $ e ++ repeat (MExpr p ANil))) <$> parseVarList <*> ((,) <$ pMTok Equals <*> pPos <*> parseExpressionList <<|> (,) <$> pPos <*> pReturn [])
            )


-- | Parse if then elseif then else end expressions
parseIf :: AParser Stat
parseIf = AIf <$ pMTok If <*> parseExpression <* pMTok Then <*>
            parseBlock <*>
            -- elseif
            pMany ((,) <$ pMTok Elseif <*> parseExpression <* pMTok Then <*> parseBlock) <*>
            -- else
            optional (pMTok Else *> parseBlock) <*
            pMTok End

-- | Parse numeric and generic for loops
parseFor :: AParser Stat
parseFor = pPacked (pMTok For) (pMTok End) (
            ANFor <$>
              pName <* pMTok Equals <*> parseExpression <*
              -- end value
              pMTok Comma <*> parseExpression <*>
              -- step (1 if not filled in)
              (pMTok Comma *> parseExpression <<|> MExpr <$> pPos <*> pReturn (ANumber "1")) <*
              pMTok Do <*> parseBlock
            <|>
            AGFor <$> parseNameList <*
              pMTok In <*> parseExpressionList <*
              pMTok Do <*> parseBlock
            )


-- | Parse a return value
parseReturn :: AParser AReturn
parseReturn = AReturn <$> pPos <* pMTok Return <*> opt parseExpressionList [] <* pMany (pMTok Semicolon)

-- | Label
parseLabel :: AParser MToken
parseLabel = pMSatisfy isLabel (Label "someLabel") "Some label"
    where
        isLabel :: MToken -> Bool
        isLabel (MToken _ (Label _)) = True
        isLabel _ = False

-- | Function name (includes dot indices and meta indices)
parseFuncName :: AParser FuncName
parseFuncName = (\a b c -> FuncName (a:b) c) <$> pName <*> pMany (pMTok Dot *> pName) <*>
                opt (Just <$ pMTok Colon <*> pName) Nothing

-- | Parse a number into an expression
parseNumber :: AParser Expr
parseNumber = (\(MToken _ (TNumber str)) -> ANumber str) <$> pMSatisfy isNumber (TNumber "0") "Number"
    where
        isNumber :: MToken -> Bool
        isNumber (MToken _ (TNumber str)) = True
        isNumber _ = False

-- | Parse any kind of string
parseString :: AParser MToken
parseString = pMSatisfy isString (DQString "someString") "String"
    where
        isString :: MToken -> Bool
        isString (MToken _ (DQString str)) = True
        isString (MToken _ (SQString str)) = True
        isString (MToken _ (MLString str)) = True
        isString _ = False

-- | Parse an identifier
pName :: AParser MToken
pName = pMSatisfy isName (Identifier "someVariable") "Variable"
    where
        isName :: MToken -> Bool
        isName (MToken _ (Identifier _)) = True
        isName _ = False

-- | Parse variable list (var1, var2, var3)
parseVarList :: AParser [PrefixExp]
parseVarList = pList1Sep (pMTok Comma) parseVar

-- | list of expressions
parseExpressionList :: AParser [MExpr]
parseExpressionList = pList1Sep (pMTok Comma) parseExpression

-- | Subexpressions, i.e. without operators
parseSubExpression :: AParser Expr
parseSubExpression = ANil <$ pMTok Nil <<|>
                  AFalse <$ pMTok TFalse <<|>
                  ATrue <$ pMTok TTrue <<|>
                  parseNumber <<|>
                  AString <$> parseString <<|>
                  AVarArg <$ pMTok VarArg <<|>
                  parseAnonymFunc <<|>
                  APrefixExpr <$> parsePrefixExp <<|>
                  ATableConstructor <$> parseTableConstructor

-- | Separate parser for anonymous function subexpression
parseAnonymFunc :: AParser Expr
parseAnonymFunc = AnonymousFunc <$
                   pMTok Function <*>
                   pPacked (pMTok LRound) (pMTok RRound) parseParList <*>
                   parseBlock <*
                   pMTok End

-- | Parse operators of the same precedence in a chain
samePrioL :: [(Token, BinOp)] -> AParser MExpr -> AParser MExpr
samePrioL ops p = pChainl (choice (map f ops)) p
  where
    choice = foldr (<<|>) pFail
    f :: (Token, BinOp) -> AParser (MExpr -> MExpr -> MExpr)
    f (t, at) = (\p e1 e2 -> MExpr p (BinOpExpr at e1 e2)) <$> pPos <* pMTok t

samePrioR :: [(Token, BinOp)] -> AParser MExpr -> AParser MExpr
samePrioR ops p = pChainr (choice (map f ops)) p
  where
    choice = foldr (<<|>) pFail
    f :: (Token, BinOp) -> AParser (MExpr -> MExpr -> MExpr)
    f (t, at) = (\p e1 e2 -> MExpr p (BinOpExpr at e1 e2)) <$> pPos <* pMTok t

-- | Parse unary operator (-, not, #)
parseUnOp :: AParser UnOp
parseUnOp = UnMinus <$ pMTok Minus <<|>
            ANot    <$ pMTok Not   <<|>
            ANot    <$ pMTok CNot  <<|>
            AHash   <$ pMTok Hash

-- | Operators, sorted by priority
-- Priority from: http://www.lua.org/manual/5.2/manual.html#3.4.7
lvl1, lvl2, lvl3, lvl4, lvl5, lvl6, lvl8 :: [(Token, BinOp)]
lvl1 = [(Or, AOr), (COr, AOr)]
lvl2 = [(And, AAnd), (CAnd, AAnd)]
lvl3 = [(TLT, ALT), (TGT, AGT), (TLEQ, ALEQ), (TGEQ, AGEQ), (TNEq, ANEq), (TCNEq, ANEq), (TEq, AEq)]
lvl4 = [(Concatenate, AConcatenate)]
lvl5 = [(Plus, APlus), (Minus, BinMinus)]
lvl6 = [(Multiply, AMultiply), (Divide, ADivide), (Modulus, AModulus)]
-- lvl7 is unary operators
lvl8 = [(Power, APower)]


-- | Parse chains of binary and unary operators
parseExpression :: AParser MExpr
parseExpression = samePrioL lvl1 $
                  samePrioL lvl2 $
                  samePrioL lvl3 $
                  samePrioR lvl4 $
                  samePrioL lvl5 $
                  samePrioL lvl6 $
                  MExpr <$> pPos <*> (UnOpExpr <$> parseUnOp <*> parseExpression) <<|> -- lvl7
                  samePrioR lvl8 (MExpr <$> pPos <*> parseSubExpression)

-- | Prefix expressions
-- can have any arbitrary list of expression suffixes
parsePrefixExp :: AParser PrefixExp
parsePrefixExp = pPrefixExp (pMany pPFExprSuffix)

-- | Prefix expressions
-- The suffixes define rules on the allowed suffixes
pPrefixExp :: AParser [PFExprSuffix] -> AParser PrefixExp
pPrefixExp suffixes = PFVar <$> pName <*> suffixes <<|>
                      ExprVar <$ pMTok LRound <*> parseExpression <* pMTok RRound <*> suffixes

-- | Parse any expression suffix
pPFExprSuffix :: AParser PFExprSuffix
pPFExprSuffix = pPFExprCallSuffix <<|> pPFExprIndexSuffix

-- | Parse an indexing expression suffix
pPFExprCallSuffix :: AParser PFExprSuffix
pPFExprCallSuffix = Call <$> parseArgs <<|>
                    MetaCall <$ pMTok Colon <*> pName <*> parseArgs

-- | Parse an indexing expression suffix
pPFExprIndexSuffix :: AParser PFExprSuffix
pPFExprIndexSuffix = ExprIndex <$ pMTok LSquare <*> parseExpression <* pMTok RSquare <<|>
                     DotIndex <$ pMTok Dot <*> pName

-- | Function calls are prefix expressions, but the last suffix MUST be either a function call or a metafunction call
pFunctionCall :: AParser PrefixExp
pFunctionCall = pPrefixExp suffixes
    where
        suffixes = concat <$> pSome ((\ix c -> ix ++ [c]) <$> pSome pPFExprIndexSuffix <*> pPFExprCallSuffix <<|>
                                     (:[])                <$> pPFExprCallSuffix)

-- | single variable. Note: definition differs from reference to circumvent the left recursion
-- var ::= Name [{PFExprSuffix}* indexation] | '(' exp ')' {PFExprSuffix}* indexation
-- where "{PFExprSuffix}* indexation" is any arbitrary sequence of prefix expression suffixes that end with an indexation
parseVar :: AParser PrefixExp
parseVar = pPrefixExp suffixes
    where
        suffixes = concat <$> pMany ((\c ix -> c ++ [ix]) <$> pSome pPFExprCallSuffix <*> pPFExprIndexSuffix <<|>
                                     (:[])                <$> pPFExprIndexSuffix)

-- | Arguments of a function call (including brackets)
parseArgs :: AParser Args
parseArgs = ListArgs <$ pMTok LRound <*> opt parseExpressionList [] <* pMTok RRound <<|>
            TableArg <$> parseTableConstructor <<|>
            StringArg <$> parseString

-- | Table constructor
parseTableConstructor :: AParser [Field]
parseTableConstructor = pMTok LCurly *> parseFieldList <* pMTok RCurly

-- | A list of table entries
-- Grammar: field {separator field} [separator]
parseFieldList :: AParser [Field]
parseFieldList = pListSep parseFieldSep parseField <* opt parseFieldSep undefined

-- | A field in a table
parseField :: AParser Field
parseField = ExprField <$ pMTok LSquare <*> parseExpression <* pMTok RSquare <* pMTok Equals <*> parseExpression <<|>
             (NamedField <$> pName <* pMTok Equals <*> parseExpression <|>
              UnnamedField <$> parseExpression)

-- | Field separator
parseFieldSep :: AParser MToken
parseFieldSep = pMTok Comma <<|> pMTok Semicolon
