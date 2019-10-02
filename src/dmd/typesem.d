/**
 * Compiler implementation of the
 * $(LINK2 http://www.dlang.org, D programming language).
 *
 * Copyright:   Copyright (C) 1999-2019 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 http://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/typesem.d, _typesem.d)
 * Documentation:  https://dlang.org/phobos/dmd_typesem.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/typesem.d
 */

module dmd.typesem;

import core.checkedint;
import core.stdc.string;
import core.stdc.stdio;

import dmd.access;
import dmd.aggregate;
import dmd.aliasthis;
import dmd.arrayop;
import dmd.arraytypes;
import dmd.astcodegen;
import dmd.complex;
import dmd.dcast;
import dmd.dclass;
import dmd.declaration;
import dmd.denum;
import dmd.dimport;
import dmd.dmangle;
import dmd.dmodule : Module;
import dmd.dscope;
import dmd.dstruct;
import dmd.dsymbol;
import dmd.dsymbolsem;
import dmd.dtemplate;
import dmd.errors;
import dmd.expression;
import dmd.expressionsem;
import dmd.func;
import dmd.globals;
import dmd.hdrgen;
import dmd.id;
import dmd.identifier;
import dmd.imphint;
import dmd.init;
import dmd.initsem;
import dmd.visitor;
import dmd.mtype;
import dmd.objc;
import dmd.opover;
import dmd.parse;
import dmd.root.ctfloat;
import dmd.root.rmem;
import dmd.root.outbuffer;
import dmd.root.rootobject;
import dmd.root.stringtable;
import dmd.semantic3;
import dmd.sideeffect;
import dmd.target;
import dmd.tokens;
import dmd.typesem;

/**************************
 * This evaluates exp while setting length to be the number
 * of elements in the tuple t.
 */
private Expression semanticLength(Scope* sc, Type t, Expression exp)
{
    if (auto tt = t.isTypeTuple())
    {
        ScopeDsymbol sym = new ArrayScopeSymbol(sc, tt);
        sym.parent = sc.scopesym;
        sc = sc.push(sym);
        sc = sc.startCTFE();
        exp = exp.expressionSemantic(sc);
        sc = sc.endCTFE();
        sc.pop();
    }
    else
    {
        sc = sc.startCTFE();
        exp = exp.expressionSemantic(sc);
        sc = sc.endCTFE();
    }
    return exp;
}

private Expression semanticLength(Scope* sc, TupleDeclaration tup, Expression exp)
{
    ScopeDsymbol sym = new ArrayScopeSymbol(sc, tup);
    sym.parent = sc.scopesym;

    sc = sc.push(sym);
    sc = sc.startCTFE();
    exp = exp.expressionSemantic(sc);
    sc = sc.endCTFE();
    sc.pop();

    return exp;
}

/*************************************
 * Resolve a tuple index.
 */
private void resolveTupleIndex(const ref Loc loc, Scope* sc, Dsymbol s, Expression* pe, Type* pt, Dsymbol* ps, RootObject oindex)
{
    *pt = null;
    *ps = null;
    *pe = null;

    auto tup = s.isTupleDeclaration();

    auto eindex = isExpression(oindex);
    auto tindex = isType(oindex);
    auto sindex = isDsymbol(oindex);

    if (!tup)
    {
        // It's really an index expression
        if (tindex)
            eindex = new TypeExp(loc, tindex);
        else if (sindex)
            eindex = symbolToExp(sindex, loc, sc, false);
        Expression e = new IndexExp(loc, symbolToExp(s, loc, sc, false), eindex);
        e = e.expressionSemantic(sc);
        resolveExp(e, pt, pe, ps);
        return;
    }

    // Convert oindex to Expression, then try to resolve to constant.
    if (tindex)
        tindex.resolve(loc, sc, &eindex, &tindex, &sindex);
    if (sindex)
        eindex = symbolToExp(sindex, loc, sc, false);
    if (!eindex)
    {
        .error(loc, "index `%s` is not an expression", oindex.toChars());
        *pt = Type.terror;
        return;
    }

    eindex = semanticLength(sc, tup, eindex);
    eindex = eindex.ctfeInterpret();
    if (eindex.op == TOK.error)
    {
        *pt = Type.terror;
        return;
    }
    const(uinteger_t) d = eindex.toUInteger();
    if (d >= tup.objects.dim)
    {
        .error(loc, "tuple index `%llu` exceeds length %u", d, tup.objects.dim);
        *pt = Type.terror;
        return;
    }

    RootObject o = (*tup.objects)[cast(size_t)d];
    *pt = isType(o);
    *ps = isDsymbol(o);
    *pe = isExpression(o);
    if (*pt)
        *pt = (*pt).typeSemantic(loc, sc);
    if (*pe)
        resolveExp(*pe, pt, pe, ps);
}

/*************************************
 * Takes an array of Identifiers and figures out if
 * it represents a Type, Expression, or Dsymbol.
 * Params:
 *      mt = array of identifiers
 *      loc = location for error messages
 *      sc = context
 *      s = symbol to start search at
 *      scopesym = unused
 *      pe = set if expression
 *      pt = set if type
 *      ps = set if symbol
 *      typeid = set if in TypeidExpression https://dlang.org/spec/expression.html#TypeidExpression
 */
private void resolveHelper(TypeQualified mt, const ref Loc loc, Scope* sc, Dsymbol s, Dsymbol scopesym,
    Expression* pe, Type* pt, Dsymbol* ps, bool intypeid = false)
{
    version (none)
    {
        printf("TypeQualified::resolveHelper(sc = %p, idents = '%s')\n", sc, mt.toChars());
        if (scopesym)
            printf("\tscopesym = '%s'\n", scopesym.toChars());
    }
    *pe = null;
    *pt = null;
    *ps = null;

    if (!s)
    {
        /* Look for what user might have intended
         */
        const p = mt.mutableOf().unSharedOf().lvalueOf().toChars();
        auto id = Identifier.idPool(p, cast(uint)strlen(p));
        if (const n = importHint(id.toString()))
            error(loc, "`%s` is not defined, perhaps `import %.*s;` ?", p, cast(int)n.length, n.ptr);
        else if (auto s2 = sc.search_correct(id))
            error(loc, "undefined identifier `%s`, did you mean %s `%s`?", p, s2.kind(), s2.toChars());
        else if (const q = Scope.search_correct_C(id))
            error(loc, "undefined identifier `%s`, did you mean `%s`?", p, q);
        else
            error(loc, "undefined identifier `%s`", p);

        *pt = Type.terror;
        return;
    }

    //printf("\t1: s = '%s' %p, kind = '%s'\n",s.toChars(), s, s.kind());
    Declaration d = s.isDeclaration();
    if (d && (d.storage_class & STC.templateparameter))
        s = s.toAlias();
    else
    {
        // check for deprecated or disabled aliases
        s.checkDeprecated(loc, sc);
        if (d)
            d.checkDisabled(loc, sc, true);
    }
    s = s.toAlias();
    //printf("\t2: s = '%s' %p, kind = '%s'\n",s.toChars(), s, s.kind());
    for (size_t i = 0; i < mt.idents.dim; i++)
    {
        RootObject id = mt.idents[i];
        if (id.dyncast() == DYNCAST.expression ||
            id.dyncast() == DYNCAST.type)
        {
            Type tx;
            Expression ex;
            Dsymbol sx;
            resolveTupleIndex(loc, sc, s, &ex, &tx, &sx, id);
            if (sx)
            {
                s = sx.toAlias();
                continue;
            }
            if (tx)
                ex = new TypeExp(loc, tx);
            assert(ex);

            ex = typeToExpressionHelper(mt, ex, i + 1);
            ex = ex.expressionSemantic(sc);
            resolveExp(ex, pt, pe, ps);
            return;
        }

        Type t = s.getType(); // type symbol, type alias, or type tuple?
        uint errorsave = global.errors;
        int flags = t is null ? SearchLocalsOnly : IgnorePrivateImports;

        Dsymbol sm = s.searchX(loc, sc, id, flags);
        if (sm && !(sc.flags & SCOPE.ignoresymbolvisibility) && !symbolIsVisible(sc, sm))
        {
            .error(loc, "`%s` is not visible from module `%s`", sm.toPrettyChars(), sc._module.toChars());
            sm = null;
        }
        if (global.errors != errorsave)
        {
            *pt = Type.terror;
            return;
        }

        void helper3()
        {
            Expression e;
            VarDeclaration v = s.isVarDeclaration();
            FuncDeclaration f = s.isFuncDeclaration();
            if (intypeid || !v && !f)
                e = symbolToExp(s, loc, sc, true);
            else
                e = new VarExp(loc, s.isDeclaration(), true);

            e = typeToExpressionHelper(mt, e, i);
            e = e.expressionSemantic(sc);
            resolveExp(e, pt, pe, ps);
        }

        //printf("\t3: s = %p %s %s, sm = %p\n", s, s.kind(), s.toChars(), sm);
        if (intypeid && !t && sm && sm.needThis())
            return helper3();

        if (VarDeclaration v = s.isVarDeclaration())
        {
            // https://issues.dlang.org/show_bug.cgi?id=19913
            // v.type would be null if it is a forward referenced member.
            if (v.type is null)
                v.dsymbolSemantic(sc);
            if (v.storage_class & (STC.const_ | STC.immutable_ | STC.manifest) ||
                v.type.isConst() || v.type.isImmutable())
            {
                // https://issues.dlang.org/show_bug.cgi?id=13087
                // this.field is not constant always
                if (!v.isThisDeclaration())
                    return helper3();
            }
        }
        if (!sm)
        {
            if (!t)
            {
                if (s.isDeclaration()) // var, func, or tuple declaration?
                {
                    t = s.isDeclaration().type;
                    if (!t && s.isTupleDeclaration()) // expression tuple?
                        return helper3();
                }
                else if (s.isTemplateInstance() ||
                         s.isImport() || s.isPackage() || s.isModule())
                {
                    return helper3();
                }
            }
            if (t)
            {
                sm = t.toDsymbol(sc);
                if (sm && id.dyncast() == DYNCAST.identifier)
                {
                    sm = sm.search(loc, cast(Identifier)id, IgnorePrivateImports);
                    if (!sm)
                        return helper3();
                }
                else
                    return helper3();
            }
            else
            {
                if (id.dyncast() == DYNCAST.dsymbol)
                {
                    // searchX already handles errors for template instances
                    assert(global.errors);
                }
                else
                {
                    assert(id.dyncast() == DYNCAST.identifier);
                    sm = s.search_correct(cast(Identifier)id);
                    if (sm)
                        error(loc, "identifier `%s` of `%s` is not defined, did you mean %s `%s`?", id.toChars(), mt.toChars(), sm.kind(), sm.toChars());
                    else
                        error(loc, "identifier `%s` of `%s` is not defined", id.toChars(), mt.toChars());
                }
                *pe = new ErrorExp();
                return;
            }
        }
        s = sm.toAlias();
    }

    if (auto em = s.isEnumMember())
    {
        // It's not a type, it's an expression
        *pe = em.getVarExp(loc, sc);
        return;
    }
    if (auto v = s.isVarDeclaration())
    {
        /* This is mostly same with DsymbolExp::semantic(), but we cannot use it
         * because some variables used in type context need to prevent lowering
         * to a literal or contextful expression. For example:
         *
         *  enum a = 1; alias b = a;
         *  template X(alias e){ alias v = e; }  alias x = X!(1);
         *  struct S { int v; alias w = v; }
         *      // TypeIdentifier 'a', 'e', and 'v' should be TOK.variable,
         *      // because getDsymbol() need to work in AliasDeclaration::semantic().
         */
        if (!v.type ||
            !v.type.deco && v.inuse)
        {
            if (v.inuse) // https://issues.dlang.org/show_bug.cgi?id=9494
                error(loc, "circular reference to %s `%s`", v.kind(), v.toPrettyChars());
            else
                error(loc, "forward reference to %s `%s`", v.kind(), v.toPrettyChars());
            *pt = Type.terror;
            return;
        }
        if (v.type.ty == Terror)
            *pt = Type.terror;
        else
            *pe = new VarExp(loc, v);
        return;
    }
    if (auto fld = s.isFuncLiteralDeclaration())
    {
        //printf("'%s' is a function literal\n", fld.toChars());
        *pe = new FuncExp(loc, fld);
        *pe = (*pe).expressionSemantic(sc);
        return;
    }
    version (none)
    {
        if (FuncDeclaration fd = s.isFuncDeclaration())
        {
            *pe = new DsymbolExp(loc, fd);
            return;
        }
    }

    Type t;
    while (1)
    {
        t = s.getType();
        if (t)
            break;
        // If the symbol is an import, try looking inside the import
        if (Import si = s.isImport())
        {
            s = si.search(loc, s.ident);
            if (s && s != si)
                continue;
            s = si;
        }
        *ps = s;
        return;
    }

    if (auto ti = t.isTypeInstance())
        if (ti != mt && !ti.deco)
        {
            if (!ti.tempinst.errors)
                error(loc, "forward reference to `%s`", ti.toChars());
            *pt = Type.terror;
            return;
        }

    if (t.ty == Ttuple)
        *pt = t;
    else
        *pt = t.merge();
}

/************************************
 * Transitively search a type for all function types.
 * If any function types with parameters are found that have parameter identifiers
 * or default arguments, remove those and create a new type stripped of those.
 * This is used to determine the "canonical" version of a type which is useful for
 * comparisons.
 * Params:
 *      t = type to scan
 * Returns:
 *      `t` if no parameter identifiers or default arguments found, otherwise a new type that is
 *      the same as t but with no parameter identifiers or default arguments.
 */
private Type stripDefaultArgs(Type t)
{
    static Parameters* stripParams(Parameters* parameters)
    {
        static Parameter stripParameter(Parameter p)
        {
            Type t = stripDefaultArgs(p.type);
            return (t != p.type || p.defaultArg || p.ident || p.userAttribDecl)
                ? new Parameter(p.storageClass, t, null, null, null)
                : null;
        }

        if (parameters)
        {
            foreach (i, p; *parameters)
            {
                Parameter ps = stripParameter(p);
                if (ps)
                {
                    // Replace params with a copy we can modify
                    Parameters* nparams = new Parameters(parameters.dim);

                    foreach (j, ref np; *nparams)
                    {
                        Parameter pj = (*parameters)[j];
                        if (j < i)
                            np = pj;
                        else if (j == i)
                            np = ps;
                        else
                        {
                            Parameter nps = stripParameter(pj);
                            np = nps ? nps : pj;
                        }
                    }
                    return nparams;
                }
            }
        }
        return parameters;
    }

    if (t is null)
        return t;

    if (auto tf = t.isTypeFunction())
    {
        Type tret = stripDefaultArgs(tf.next);
        Parameters* params = stripParams(tf.parameterList.parameters);
        if (tret == tf.next && params == tf.parameterList.parameters)
            return t;
        TypeFunction tr = cast(TypeFunction)tf.copy();
        tr.parameterList.parameters = params;
        tr.next = tret;
        //printf("strip %s\n   <- %s\n", tr.toChars(), t.toChars());
        return tr;
    }
    else if (auto tt = t.isTypeTuple())
    {
        Parameters* args = stripParams(tt.arguments);
        if (args == tt.arguments)
            return t;
        TypeTuple tr = cast(TypeTuple)t.copy();
        tr.arguments = args;
        return tr;
    }
    else if (t.ty == Tenum)
    {
        // TypeEnum::nextOf() may be != NULL, but it's not necessary here.
        return t;
    }
    else
    {
        Type tn = t.nextOf();
        Type n = stripDefaultArgs(tn);
        if (n == tn)
            return t;
        TypeNext tr = cast(TypeNext)t.copy();
        tr.next = n;
        return tr;
    }
}

/******************************************
 * We've mistakenly parsed `t` as a type.
 * Redo `t` as an Expression.
 * Params:
 *      t = mistaken type
 * Returns:
 *      t redone as Expression, null if cannot
 */
Expression typeToExpression(Type t)
{
    static Expression visitSArray(TypeSArray t)
    {
        if (auto e = t.next.typeToExpression())
            return new ArrayExp(t.dim.loc, e, t.dim);
        return null;
    }

    static Expression visitAArray(TypeAArray t)
    {
        if (auto e = t.next.typeToExpression())
        {
            if (auto ei = t.index.typeToExpression())
                return new ArrayExp(t.loc, e, ei);
        }
        return null;
    }

    static Expression visitIdentifier(TypeIdentifier t)
    {
        return typeToExpressionHelper(t, new IdentifierExp(t.loc, t.ident));
    }

    static Expression visitInstance(TypeInstance t)
    {
        return typeToExpressionHelper(t, new ScopeExp(t.loc, t.tempinst));
    }

    switch (t.ty)
    {
        case Tsarray:   return visitSArray(cast(TypeSArray) t);
        case Taarray:   return visitAArray(cast(TypeAArray) t);
        case Tident:    return visitIdentifier(cast(TypeIdentifier) t);
        case Tinstance: return visitInstance(cast(TypeInstance) t);
        default:        return null;
    }
}

/* Helper function for `typeToExpression`. Contains common code
 * for TypeQualified derived classes.
 */
Expression typeToExpressionHelper(TypeQualified t, Expression e, size_t i = 0)
{
    //printf("toExpressionHelper(e = %s %s)\n", Token.toChars(e.op), e.toChars());
    foreach (id; t.idents[i .. t.idents.dim])
    {
        //printf("\t[%d] e: '%s', id: '%s'\n", i, e.toChars(), id.toChars());

        final switch (id.dyncast())
        {
            // ... '. ident'
            case DYNCAST.identifier:
                e = new DotIdExp(e.loc, e, cast(Identifier)id);
                break;

            // ... '. name!(tiargs)'
            case DYNCAST.dsymbol:
                auto ti = (cast(Dsymbol)id).isTemplateInstance();
                assert(ti);
                e = new DotTemplateInstanceExp(e.loc, e, ti.name, ti.tiargs);
                break;

            // ... '[type]'
            case DYNCAST.type:          // https://issues.dlang.org/show_bug.cgi?id=1215
                e = new ArrayExp(t.loc, e, new TypeExp(t.loc, cast(Type)id));
                break;

            // ... '[expr]'
            case DYNCAST.expression:    // https://issues.dlang.org/show_bug.cgi?id=1215
                e = new ArrayExp(t.loc, e, cast(Expression)id);
                break;

            case DYNCAST.object:
            case DYNCAST.tuple:
            case DYNCAST.parameter:
            case DYNCAST.statement:
            case DYNCAST.condition:
            case DYNCAST.templateparameter:
                assert(0);
        }
    }
    return e;
}

/******************************************
 * Perform semantic analysis on a type.
 * Params:
 *      t = Type AST node
 *      loc = the location of the type
 *      sc = context
 * Returns:
 *      `Type` with completed semantic analysis, `Terror` if errors
 *      were encountered
 */
extern(C++) Type typeSemantic(Type t, Loc loc, Scope* sc)
{
    static Type error()
    {
        return Type.terror;
    }

    Type visitType(Type t)
    {
        if (t.ty == Tint128 || t.ty == Tuns128)
        {
            .error(loc, "`cent` and `ucent` types not implemented");
            return error();
        }

        return t.merge();
    }

    Type visitVector(TypeVector mtype)
    {
        const errors = global.errors;
        mtype.basetype = mtype.basetype.typeSemantic(loc, sc);
        if (errors != global.errors)
            return error();
        mtype.basetype = mtype.basetype.toBasetype().mutableOf();
        if (mtype.basetype.ty != Tsarray)
        {
            .error(loc, "T in __vector(T) must be a static array, not `%s`", mtype.basetype.toChars());
            return error();
        }
        TypeSArray t = cast(TypeSArray)mtype.basetype;
        const sz = cast(int)t.size(loc);
        final switch (target.isVectorTypeSupported(sz, t.nextOf()))
        {
        case 0:
            // valid
            break;

        case 1:
            // no support at all
            .error(loc, "SIMD vector types not supported on this platform");
            return error();

        case 2:
            // invalid base type
            .error(loc, "vector type `%s` is not supported on this platform", mtype.toChars());
            return error();

        case 3:
            // invalid size
            .error(loc, "%d byte vector type `%s` is not supported on this platform", sz, mtype.toChars());
            return error();
        }
        return merge(mtype);
    }

    Type visitSArray(TypeSArray mtype)
    {
        //printf("TypeSArray::semantic() %s\n", toChars());
        Type t;
        Expression e;
        Dsymbol s;
        mtype.next.resolve(loc, sc, &e, &t, &s);

        if (auto tup = s ? s.isTupleDeclaration() : null)
        {
            mtype.dim = semanticLength(sc, tup, mtype.dim);
            mtype.dim = mtype.dim.ctfeInterpret();
            if (mtype.dim.op == TOK.error)
                return error();

            uinteger_t d = mtype.dim.toUInteger();
            if (d >= tup.objects.dim)
            {
                .error(loc, "tuple index %llu exceeds %llu", cast(ulong)d, cast(ulong)tup.objects.dim);
                return error();
            }

            RootObject o = (*tup.objects)[cast(size_t)d];
            if (o.dyncast() != DYNCAST.type)
            {
                .error(loc, "`%s` is not a type", mtype.toChars());
                return error();
            }
            return (cast(Type)o).addMod(mtype.mod);
        }

        Type tn = mtype.next.typeSemantic(loc, sc);
        if (tn.ty == Terror)
            return error();

        Type tbn = tn.toBasetype();
        if (mtype.dim)
        {
            //https://issues.dlang.org/show_bug.cgi?id=15478
            if (mtype.dim.isDotVarExp())
            {
                if (Declaration vd = mtype.dim.isDotVarExp().var)
                {
                    FuncDeclaration fd = vd.toAlias().isFuncDeclaration();
                    if (fd)
                        mtype.dim = new CallExp(loc, fd, null);
                }
            }

            auto errors = global.errors;
            mtype.dim = semanticLength(sc, tbn, mtype.dim);
            if (errors != global.errors)
                return error();

            mtype.dim = mtype.dim.optimize(WANTvalue);
            mtype.dim = mtype.dim.ctfeInterpret();
            if (mtype.dim.op == TOK.error)
                return error();

            errors = global.errors;
            dinteger_t d1 = mtype.dim.toInteger();
            if (errors != global.errors)
                return error();

            mtype.dim = mtype.dim.implicitCastTo(sc, Type.tsize_t);
            mtype.dim = mtype.dim.optimize(WANTvalue);
            if (mtype.dim.op == TOK.error)
                return error();

            errors = global.errors;
            dinteger_t d2 = mtype.dim.toInteger();
            if (errors != global.errors)
                return error();

            if (mtype.dim.op == TOK.error)
                return error();

            Type overflowError()
            {
                .error(loc, "`%s` size %llu * %llu exceeds 0x%llx size limit for static array",
                        mtype.toChars(), cast(ulong)tbn.size(loc), cast(ulong)d1, target.maxStaticDataSize);
                return error();
            }

            if (d1 != d2)
                return overflowError();

            Type tbx = tbn.baseElemOf();
            if (tbx.ty == Tstruct && !(cast(TypeStruct)tbx).sym.members ||
                tbx.ty == Tenum && !(cast(TypeEnum)tbx).sym.members)
            {
                /* To avoid meaningless error message, skip the total size limit check
                 * when the bottom of element type is opaque.
                 */
            }
            else if (tbn.isTypeBasic() ||
                     tbn.ty == Tpointer ||
                     tbn.ty == Tarray ||
                     tbn.ty == Tsarray ||
                     tbn.ty == Taarray ||
                     (tbn.ty == Tstruct && ((cast(TypeStruct)tbn).sym.sizeok == Sizeok.done)) ||
                     tbn.ty == Tclass)
            {
                /* Only do this for types that don't need to have semantic()
                 * run on them for the size, since they may be forward referenced.
                 */
                bool overflow = false;
                if (mulu(tbn.size(loc), d2, overflow) >= target.maxStaticDataSize || overflow)
                    return overflowError();
            }
        }
        switch (tbn.ty)
        {
        case Ttuple:
            {
                // Index the tuple to get the type
                assert(mtype.dim);
                TypeTuple tt = cast(TypeTuple)tbn;
                uinteger_t d = mtype.dim.toUInteger();
                if (d >= tt.arguments.dim)
                {
                    .error(loc, "tuple index %llu exceeds %llu", cast(ulong)d, cast(ulong)tt.arguments.dim);
                    return error();
                }
                Type telem = (*tt.arguments)[cast(size_t)d].type;
                return telem.addMod(mtype.mod);
            }

        case Tfunction:
        case Tnone:
            .error(loc, "cannot have array of `%s`", tbn.toChars());
            return error();

        default:
            break;
        }
        if (tbn.isscope())
        {
            .error(loc, "cannot have array of scope `%s`", tbn.toChars());
            return error();
        }
        if (tbn.isrvalue)
        {
            .error(loc, "cannot have array of `@rvalue` type");
            return error();
        }

        /* Ensure things like const(immutable(T)[3]) become immutable(T[3])
         * and const(T)[3] become const(T[3])
         */
        mtype.next = tn;
        mtype.transitive();
        return mtype.addMod(tn.mod).merge();
    }

    Type visitDArray(TypeDArray mtype)
    {
        Type tn = mtype.next.typeSemantic(loc, sc);
        Type tbn = tn.toBasetype();
        switch (tbn.ty)
        {
        case Ttuple:
            return tbn;

        case Tfunction:
        case Tnone:
            .error(loc, "cannot have array of `%s`", tbn.toChars());
            return error();

        case Terror:
            return error();

        default:
            break;
        }
        if (tn.isscope())
        {
            .error(loc, "cannot have array of scope `%s`", tn.toChars());
            return error();
        }
        if (tn.isrvalue)
        {
            .error(loc, "cannot have array of `@rvalue` type");
            return error();
        }
        mtype.next = tn;
        mtype.transitive();
        return merge(mtype);
    }

    Type visitAArray(TypeAArray mtype)
    {
        //printf("TypeAArray::semantic() %s index.ty = %d\n", mtype.toChars(), mtype.index.ty);
        if (mtype.deco)
        {
            return mtype;
        }

        mtype.loc = loc;
        mtype.sc = sc;
        if (sc)
            sc.setNoFree();

        // Deal with the case where we thought the index was a type, but
        // in reality it was an expression.
        if (mtype.index.ty == Tident || mtype.index.ty == Tinstance || mtype.index.ty == Tsarray || mtype.index.ty == Ttypeof || mtype.index.ty == Treturn)
        {
            Expression e;
            Type t;
            Dsymbol s;
            mtype.index.resolve(loc, sc, &e, &t, &s);

            //https://issues.dlang.org/show_bug.cgi?id=15478
            if (s)
            {
                if (FuncDeclaration fd = s.toAlias().isFuncDeclaration())
                    e = new CallExp(loc, fd, null);
            }

            if (e)
            {
                // It was an expression -
                // Rewrite as a static array
                auto tsa = new TypeSArray(mtype.next, e);
                return tsa.typeSemantic(loc, sc);
            }
            else if (t)
                mtype.index = t.typeSemantic(loc, sc);
            else
            {
                .error(loc, "index is not a type or an expression");
                return error();
            }
        }
        else
            mtype.index = mtype.index.typeSemantic(loc, sc);
        mtype.index = mtype.index.merge2();

        if (mtype.index.nextOf() && !mtype.index.nextOf().isImmutable())
        {
            mtype.index = mtype.index.constOf().mutableOf();
            version (none)
            {
                printf("index is %p %s\n", mtype.index, mtype.index.toChars());
                mtype.index.check();
                printf("index.mod = x%x\n", mtype.index.mod);
                printf("index.ito = x%x\n", mtype.index.ito);
                if (mtype.index.ito)
                {
                    printf("index.ito.mod = x%x\n", mtype.index.ito.mod);
                    printf("index.ito.ito = x%x\n", mtype.index.ito.ito);
                }
            }
        }

        switch (mtype.index.toBasetype().ty)
        {
        case Tfunction:
        case Tvoid:
        case Tnone:
        case Ttuple:
            .error(loc, "cannot have associative array key of `%s`", mtype.index.toBasetype().toChars());
            goto case Terror;
        case Terror:
            return error();

        default:
            break;
        }
        Type tbase = mtype.index.baseElemOf();
        while (tbase.ty == Tarray)
            tbase = tbase.nextOf().baseElemOf();
        if (auto ts = tbase.isTypeStruct())
        {
            /* AA's need typeid(index).equals() and getHash(). Issue error if not correctly set up.
             */
            StructDeclaration sd = ts.sym;
            if (sd.semanticRun < PASS.semanticdone)
                sd.dsymbolSemantic(null);

            // duplicate a part of StructDeclaration::semanticTypeInfoMembers
            //printf("AA = %s, key: xeq = %p, xerreq = %p xhash = %p\n", toChars(), sd.xeq, sd.xerreq, sd.xhash);
            if (sd.xeq && sd.xeq._scope && sd.xeq.semanticRun < PASS.semantic3done)
            {
                uint errors = global.startGagging();
                sd.xeq.semantic3(sd.xeq._scope);
                if (global.endGagging(errors))
                    sd.xeq = sd.xerreq;
            }

            //printf("AA = %s, key: xeq = %p, xhash = %p\n", toChars(), sd.xeq, sd.xhash);
            const(char)* s = (mtype.index.toBasetype().ty != Tstruct) ? "bottom of " : "";
            if (!sd.xeq)
            {
                // If sd.xhash != NULL:
                //   sd or its fields have user-defined toHash.
                //   AA assumes that its result is consistent with bitwise equality.
                // else:
                //   bitwise equality & hashing
            }
            else if (sd.xeq == sd.xerreq)
            {
                if (search_function(sd, Id.eq))
                {
                    .error(loc, "%sAA key type `%s` does not have `bool opEquals(ref const %s) const`", s, sd.toChars(), sd.toChars());
                }
                else
                {
                    .error(loc, "%sAA key type `%s` does not support const equality", s, sd.toChars());
                }
                return error();
            }
            else if (!sd.xhash)
            {
                if (search_function(sd, Id.eq))
                {
                    .error(loc, "%sAA key type `%s` should have `size_t toHash() const nothrow @safe` if `opEquals` defined", s, sd.toChars());
                }
                else
                {
                    .error(loc, "%sAA key type `%s` supports const equality but doesn't support const hashing", s, sd.toChars());
                }
                return error();
            }
            else
            {
                // defined equality & hashing
                assert(sd.xeq && sd.xhash);

                /* xeq and xhash may be implicitly defined by compiler. For example:
                 *   struct S { int[] arr; }
                 * With 'arr' field equality and hashing, compiler will implicitly
                 * generate functions for xopEquals and xtoHash in TypeInfo_Struct.
                 */
            }
        }
        else if (tbase.ty == Tclass && !(cast(TypeClass)tbase).sym.isInterfaceDeclaration())
        {
            ClassDeclaration cd = (cast(TypeClass)tbase).sym;
            if (cd.semanticRun < PASS.semanticdone)
                cd.dsymbolSemantic(null);

            if (!ClassDeclaration.object)
            {
                .error(Loc.initial, "missing or corrupt object.d");
                fatal();
            }

            __gshared FuncDeclaration feq = null;
            __gshared FuncDeclaration fcmp = null;
            __gshared FuncDeclaration fhash = null;
            if (!feq)
                feq = search_function(ClassDeclaration.object, Id.eq).isFuncDeclaration();
            if (!fcmp)
                fcmp = search_function(ClassDeclaration.object, Id.cmp).isFuncDeclaration();
            if (!fhash)
                fhash = search_function(ClassDeclaration.object, Id.tohash).isFuncDeclaration();
            assert(fcmp && feq && fhash);

            if (feq.vtblIndex < cd.vtbl.dim && cd.vtbl[feq.vtblIndex] == feq)
            {
                version (all)
                {
                    if (fcmp.vtblIndex < cd.vtbl.dim && cd.vtbl[fcmp.vtblIndex] != fcmp)
                    {
                        const(char)* s = (mtype.index.toBasetype().ty != Tclass) ? "bottom of " : "";
                        .error(loc, "%sAA key type `%s` now requires equality rather than comparison", s, cd.toChars());
                        errorSupplemental(loc, "Please override `Object.opEquals` and `Object.toHash`.");
                    }
                }
            }
        }
        if (mtype.index.isrvalue)
        {
            .error(loc, "cannot have associative array key of `@rvalue` type");
            return error();
        }
        mtype.next = mtype.next.typeSemantic(loc, sc).merge2();
        mtype.transitive();

        switch (mtype.next.toBasetype().ty)
        {
        case Tfunction:
        case Tvoid:
        case Tnone:
        case Ttuple:
            .error(loc, "cannot have associative array of `%s`", mtype.next.toChars());
            goto case Terror;
        case Terror:
            return error();
        default:
            break;
        }
        if (mtype.next.isscope())
        {
            .error(loc, "cannot have array of scope `%s`", mtype.next.toChars());
            return error();
        }
        if (mtype.next.isrvalue)
        {
            .error(loc, "cannot have associative array of `@rvalue` type");
            return error();
        }
        return merge(mtype);
    }

    Type visitPointer(TypePointer mtype)
    {
        //printf("TypePointer::semantic() %s\n", toChars());
        if (mtype.deco)
        {
            return mtype;
        }
        Type n = mtype.next.typeSemantic(loc, sc);
        switch (n.toBasetype().ty)
        {
        case Ttuple:
            .error(loc, "cannot have pointer to `%s`", n.toChars());
            goto case Terror;
        case Terror:
            return error();
        default:
            break;
        }
        if (n != mtype.next)
        {
            mtype.deco = null;
        }
        mtype.next = n;
        if (mtype.next.ty != Tfunction)
        {
            mtype.transitive();
            return merge(mtype);
        }
        version (none)
        {
            return merge(mtype);
        }
        else
        {
            mtype.deco = merge(mtype).deco;
            /* Don't return merge(), because arg identifiers and default args
             * can be different
             * even though the types match
             */
            return mtype;
        }
    }

    Type visitReference(TypeReference mtype)
    {
        //printf("TypeReference::semantic()\n");
        Type n = mtype.next.typeSemantic(loc, sc);
        if (n != mtype.next)
           mtype.deco = null;
        mtype.next = n;
        mtype.transitive();
        return merge(mtype);
    }

    Type visitFunction(TypeFunction mtype)
    {
        if (mtype.deco) // if semantic() already run
        {
            //printf("already done\n");
            return mtype;
        }
        //printf("TypeFunction::semantic() this = %p\n", this);
        //printf("TypeFunction::semantic() %s, sc.stc = %llx, fargs = %p\n", toChars(), sc.stc, fargs);

        bool errors = false;

        if (mtype.inuse > 500)
        {
            mtype.inuse = 0;
            .error(loc, "recursive type");
            return error();
        }

        /* Copy in order to not mess up original.
         * This can produce redundant copies if inferring return type,
         * as semantic() will get called again on this.
         */
        TypeFunction tf = mtype.copy().toTypeFunction();
        if (mtype.parameterList.parameters)
        {
            tf.parameterList.parameters = mtype.parameterList.parameters.copy();
            for (size_t i = 0; i < mtype.parameterList.parameters.dim; i++)
            {
                Parameter p = cast(Parameter)mem.xmalloc(__traits(classInstanceSize, Parameter));
                memcpy(cast(void*)p, cast(void*)(*mtype.parameterList.parameters)[i], __traits(classInstanceSize, Parameter));
                (*tf.parameterList.parameters)[i] = p;
            }
        }

        if (sc.stc & STC.pure_)
            tf.purity = PURE.fwdref;
        if (sc.stc & STC.nothrow_)
            tf.isnothrow = true;
        if (sc.stc & STC.nogc)
            tf.isnogc = true;
        if (sc.stc & STC.ref_)
            tf.isref = true;
        if (sc.stc & STC.rvalueref)
            tf.isrvalueref = true;
        if (sc.stc & STC.return_)
            tf.isreturn = true;
        if (sc.stc & STC.returninferred)
            tf.isreturninferred = true;
        if (sc.stc & STC.scope_)
            tf.isscope = true;
        if (sc.stc & STC.scopeinferred)
            tf.isscopeinferred = true;

//        if (tf.isreturn && !tf.isref)
//            tf.isscope = true;                                  // return by itself means 'return scope'

        if (tf.trust == TRUST.default_)
        {
            if (sc.stc & STC.safe)
                tf.trust = TRUST.safe;
            else if (sc.stc & STC.system)
                tf.trust = TRUST.system;
            else if (sc.stc & STC.trusted)
                tf.trust = TRUST.trusted;
        }

        if (sc.stc & STC.property)
            tf.isproperty = true;

        tf.linkage = sc.linkage;
        version (none)
        {
            /* If the parent is @safe, then this function defaults to safe
             * too.
             * If the parent's @safe-ty is inferred, then this function's @safe-ty needs
             * to be inferred first.
             */
            if (tf.trust == TRUST.default_)
                for (Dsymbol p = sc.func; p; p = p.toParent2())
                {
                    FuncDeclaration fd = p.isFuncDeclaration();
                    if (fd)
                    {
                        if (fd.isSafeBypassingInference())
                            tf.trust = TRUST.safe; // default to @safe
                        break;
                    }
                }
        }

        bool wildreturn = false;
        if (tf.next)
        {
            sc = sc.push();
            sc.stc &= ~(STC.TYPECTOR | STC.FUNCATTR);
            tf.next = tf.next.typeSemantic(loc, sc);
            sc = sc.pop();
            errors |= tf.checkRetType(loc);
            if (tf.next.isscope() && !(sc.flags & SCOPE.ctor))
            {
                .error(loc, "functions cannot return `scope %s`", tf.next.toChars());
                errors = true;
            }
            if (tf.next.isrvalue && !tf.isref)
            {
                .error(loc, "functions cannot return `@rvalue` types except by `ref`");
                errors = true;
            }
            if (tf.next.hasWild())
                wildreturn = true;

            if (tf.isreturn && !tf.isref && !tf.next.hasPointers())
            {
                tf.isreturn = false;
            }
        }

        if (tf.isrvalueref)
            tf.isref = true;

        ubyte wildparams = 0;
        if (tf.parameterList.parameters)
        {
            /* Create a scope for evaluating the default arguments for the parameters
             */
            Scope* argsc = sc.push();
            argsc.stc = 0; // don't inherit storage class
            argsc.protection = Prot(Prot.Kind.public_);
            argsc.func = null;

            size_t dim = tf.parameterList.length;
            for (size_t i = 0; i < dim; i++)
            {
                Parameter fparam = tf.parameterList[i];
                mtype.inuse++;
                fparam.type = fparam.type.typeSemantic(loc, argsc);
                mtype.inuse--;
                if (fparam.type.ty == Terror)
                {
                    errors = true;
                    continue;
                }

                if (fparam.storageClass & STC.rvalueref)
                    fparam.storageClass |= STC.ref_;

                fparam.type = fparam.type.addStorageClass(fparam.storageClass);

                if (fparam.storageClass & (STC.auto_ | STC.alias_ | STC.static_))
                {
                    if (!fparam.type)
                        continue;
                }

                if (fparam.type.isrvalue && !(fparam.storageClass & STC.ref_))
                {
                    .error(loc, "only `ref` parameters can be `@rvalue`");
                    errors = true;
                }

                Type t = fparam.type.toBasetype();

                if (t.ty == Tfunction)
                {
                    .error(loc, "cannot have parameter of function type `%s`", fparam.type.toChars());
                    errors = true;
                }
                else if (!(fparam.storageClass & (STC.ref_ | STC.out_)) &&
                         (t.ty == Tstruct || t.ty == Tsarray || t.ty == Tenum))
                {
                    Type tb2 = t.baseElemOf();
                    if (tb2.ty == Tstruct && !(cast(TypeStruct)tb2).sym.members ||
                        tb2.ty == Tenum && !(cast(TypeEnum)tb2).sym.memtype)
                    {
                        .error(loc, "cannot have parameter of opaque type `%s` by value", fparam.type.toChars());
                        errors = true;
                    }
                }
                else if (!(fparam.storageClass & STC.lazy_) && t.ty == Tvoid)
                {
                    .error(loc, "cannot have parameter of type `%s`", fparam.type.toChars());
                    errors = true;
                }

                if ((fparam.storageClass & (STC.ref_ | STC.wild)) == (STC.ref_ | STC.wild))
                {
                    // 'ref inout' implies 'return'
                    fparam.storageClass |= STC.return_;
                }

                if (fparam.storageClass & STC.return_)
                {
                    if (fparam.storageClass & (STC.ref_ | STC.out_))
                    {
                        // Disabled for the moment awaiting improvement to allow return by ref
                        // to be transformed into return by scope.
                        if (0 && !tf.isref)
                        {
                            auto stc = fparam.storageClass & (STC.ref_ | STC.out_);
                            .error(loc, "parameter `%s` is `return %s` but function does not return by `ref`",
                                fparam.ident ? fparam.ident.toChars() : "",
                                stcToChars(stc));
                            errors = true;
                        }
                    }
                    else
                    {
                        if (!(fparam.storageClass & STC.scope_))
                            fparam.storageClass |= STC.scope_ | STC.scopeinferred; // 'return' implies 'scope'
                        if (tf.isref)
                        {
                        }
                        else if (tf.next && !tf.next.hasPointers() && tf.next.toBasetype().ty != Tvoid)
                        {
                            fparam.storageClass &= ~STC.return_;   // https://issues.dlang.org/show_bug.cgi?id=18963
                        }
                    }
                }

                if (fparam.storageClass & (STC.ref_ | STC.lazy_))
                {
                }
                else if (fparam.storageClass & STC.out_)
                {
                    if (ubyte m = fparam.type.mod & (MODFlags.immutable_ | MODFlags.const_ | MODFlags.wild))
                    {
                        .error(loc, "cannot have `%s out` parameter of type `%s`", MODtoChars(m), t.toChars());
                        errors = true;
                    }
                    else
                    {
                        Type tv = t.baseElemOf();
                        if (tv.ty == Tstruct && (cast(TypeStruct)tv).sym.noDefaultCtor)
                        {
                            .error(loc, "cannot have `out` parameter of type `%s` because the default construction is disabled", fparam.type.toChars());
                            errors = true;
                        }
                    }
                }

                if (fparam.storageClass & STC.scope_ && !fparam.type.hasPointers() && fparam.type.ty != Ttuple)
                {
                    /*     X foo(ref return scope X) => Ref-ReturnScope
                     * ref X foo(ref return scope X) => ReturnRef-Scope
                     * But X has no pointers, we don't need the scope part, so:
                     *     X foo(ref return scope X) => Ref
                     * ref X foo(ref return scope X) => ReturnRef
                     * Constructors are treated as if they are being returned through the hidden parameter,
                     * which is by ref, and the ref there is ignored.
                     */
                    fparam.storageClass &= ~STC.scope_;
                    if (!tf.isref || (sc.flags & SCOPE.ctor))
                        fparam.storageClass &= ~STC.return_;
                }

                if (t.hasWild())
                {
                    wildparams |= 1;
                    //if (tf.next && !wildreturn)
                    //    error(loc, "inout on parameter means inout must be on return type as well (if from D1 code, replace with `ref`)");
                }

                if (fparam.defaultArg)
                {
                    Expression e = fparam.defaultArg;
                    const isRefOrOut = fparam.storageClass & (STC.ref_ | STC.out_);
                    const isAuto = fparam.storageClass & (STC.auto_ | STC.autoref);
                    const isRvalueRef = fparam.storageClass & STC.rvalueref || fparam.type.isrvalue;
                    if (isRefOrOut && !isAuto && !(isRvalueRef && !e.isLvalue()))
                    {
                        e = e.expressionSemantic(argsc);
                        e = resolveProperties(argsc, e);
                    }
                    else
                    {
                        e = inferType(e, fparam.type);
                        Initializer iz = new ExpInitializer(e.loc, e);
                        iz = iz.initializerSemantic(argsc, fparam.type, INITnointerpret);
                        e = iz.initializerToExpression();
                    }
                    if (e.op == TOK.function_) // https://issues.dlang.org/show_bug.cgi?id=4820
                    {
                        FuncExp fe = cast(FuncExp)e;
                        // Replace function literal with a function symbol,
                        // since default arg expression must be copied when used
                        // and copying the literal itself is wrong.
                        e = new VarExp(e.loc, fe.fd, false);
                        e = new AddrExp(e.loc, e);
                        e = e.expressionSemantic(argsc);
                    }

                    // default arg must be an rvalue
                    if (isRvalueRef && !isAuto &&
                        e.isLvalue() && !e.type.isrvalue && !e.isRvalueRef())
                    {
                        .error(loc, "cannot pass lvalue default argument `%s` to parameter `%s`", e.toChars(), parameterToChars(fparam, tf, false));
                        errors = true;
                    }

                    e = e.implicitCastTo(argsc, fparam.type);

                    // default arg must be an lvalue
                    if (isRefOrOut && !isRvalueRef && !isAuto)
                        e = e.toLvalue(argsc, e);

                    fparam.defaultArg = e;
                    if (e.op == TOK.error)
                        errors = true;
                }

                /* If fparam after semantic() turns out to be a tuple, the number of parameters may
                 * change.
                 */
                if (auto tt = t.isTypeTuple())
                {
                    /* TypeFunction::parameter also is used as the storage of
                     * Parameter objects for FuncDeclaration. So we should copy
                     * the elements of TypeTuple::arguments to avoid unintended
                     * sharing of Parameter object among other functions.
                     */
                    if (tt.arguments && tt.arguments.dim)
                    {
                        /* Propagate additional storage class from tuple parameters to their
                         * element-parameters.
                         * Make a copy, as original may be referenced elsewhere.
                         */
                        size_t tdim = tt.arguments.dim;
                        auto newparams = new Parameters(tdim);
                        for (size_t j = 0; j < tdim; j++)
                        {
                            Parameter narg = (*tt.arguments)[j];

                            // https://issues.dlang.org/show_bug.cgi?id=12744
                            // If the storage classes of narg
                            // conflict with the ones in fparam, it's ignored.
                            StorageClass stc  = fparam.storageClass | narg.storageClass;
                            StorageClass stc1 = fparam.storageClass & (STC.ref_ | STC.rvalueref | STC.out_ | STC.lazy_);
                            StorageClass stc2 =   narg.storageClass & (STC.ref_ | STC.rvalueref | STC.out_ | STC.lazy_);
                            if (stc1 && stc2 && stc1 != stc2)
                            {
                                OutBuffer buf1;  stcToBuffer(&buf1, stc1 | ((stc1 & STC.ref_) ? (fparam.storageClass & STC.auto_) : 0));
                                OutBuffer buf2;  stcToBuffer(&buf2, stc2);

                                .error(loc, "incompatible parameter storage classes `%s` and `%s`",
                                    buf1.peekChars(), buf2.peekChars());
                                errors = true;
                                stc = stc1 | (stc & ~(STC.ref_ | STC.rvalueref | STC.out_ | STC.lazy_));
                            }

                            /* https://issues.dlang.org/show_bug.cgi?id=18572
                             *
                             * If a tuple parameter has a default argument, when expanding the parameter
                             * tuple the default argument tuple must also be expanded.
                             */
                            Expression paramDefaultArg = narg.defaultArg;
                            TupleExp te = fparam.defaultArg ? fparam.defaultArg.isTupleExp() : null;
                            if (te && te.exps && te.exps.length)
                                paramDefaultArg = (*te.exps)[j];

                            (*newparams)[j] = new Parameter(
                                stc, narg.type, narg.ident, paramDefaultArg, narg.userAttribDecl);
                        }
                        fparam.type = new TypeTuple(newparams);
                    }
                    fparam.storageClass = 0;

                    /* Reset number of parameters, and back up one to do this fparam again,
                     * now that it is a tuple
                     */
                    dim = tf.parameterList.length;
                    i--;
                    continue;
                }

                /* Resolve "auto ref" storage class to be either ref or value,
                 * based on the argument matching the parameter
                 */
                if (fparam.storageClass & STC.auto_)
                {
                    Expression farg = mtype.fargs && i < mtype.fargs.dim ? (*mtype.fargs)[i] : fparam.defaultArg;
                    if (farg && (fparam.storageClass & (STC.ref_ | STC.rvalueref)))
                    {
                        if (farg.isLvalue() && !farg.isRvalueRef())
                        {
                            // ref parameter
                            fparam.storageClass &= ~STC.rvalueref;
                        }
                        else
                        {
                            // value or rvalue ref parameter
                            if (!(fparam.storageClass & STC.rvalueref))
                                fparam.storageClass &= ~STC.ref_;
                        }
                        fparam.storageClass &= ~STC.auto_;    // https://issues.dlang.org/show_bug.cgi?id=14656
                        fparam.storageClass |= STC.autoref;
                    }
                    else if (mtype.incomplete && (fparam.storageClass & (STC.ref_ | STC.rvalueref)))
                    {
                        // the default argument may have been temporarily removed,
                        // see usage of `TypeFunction.incomplete`.
                        // https://issues.dlang.org/show_bug.cgi?id=19891
                        fparam.storageClass &= ~STC.auto_;
                        fparam.storageClass |= STC.autoref;
                    }
                    else
                    {
                        .error(loc, "`auto` can only be used as part of `auto ref` for template function parameters");
                        errors = true;
                    }
                }

                // Remove redundant storage classes for type, they are already applied
                fparam.storageClass &= ~(STC.TYPECTOR | STC.in_);
            }
            argsc.pop();
        }
        if (tf.isWild())
            wildparams |= 2;

        if (wildreturn && !wildparams)
        {
            .error(loc, "`inout` on `return` means `inout` must be on a parameter as well for `%s`", mtype.toChars());
            errors = true;
        }
        tf.iswild = wildparams;

        if (tf.isproperty && (tf.parameterList.varargs != VarArg.none || tf.parameterList.length > 2))
        {
            .error(loc, "properties can only have zero, one, or two parameter");
            errors = true;
        }

        if (tf.parameterList.varargs == VarArg.variadic && tf.linkage != LINK.d && tf.parameterList.length == 0)
        {
            .error(loc, "variadic functions with non-D linkage must have at least one parameter");
            errors = true;
        }

        if (errors)
            return error();

        if (tf.next)
            tf.deco = tf.merge().deco;

        /* Don't return merge(), because arg identifiers and default args
         * can be different
         * even though the types match
         */
        return tf;
    }

    Type visitDelegate(TypeDelegate mtype)
    {
        //printf("TypeDelegate::semantic() %s\n", toChars());
        if (mtype.deco) // if semantic() already run
        {
            //printf("already done\n");
            return mtype;
        }
        mtype.next = mtype.next.typeSemantic(loc, sc);
        if (mtype.next.ty != Tfunction)
            return error();

        /* In order to deal with https://issues.dlang.org/show_bug.cgi?id=4028
         * perhaps default arguments should
         * be removed from next before the merge.
         */
        version (none)
        {
            return mtype.merge();
        }
        else
        {
            /* Don't return merge(), because arg identifiers and default args
             * can be different
             * even though the types match
             */
            mtype.deco = mtype.merge().deco;
            return mtype;
        }
    }

    Type visitIdentifier(TypeIdentifier mtype)
    {
        Type t;
        Expression e;
        Dsymbol s;
        //printf("TypeIdentifier::semantic(%s)\n", mtype.toChars());
        mtype.resolve(loc, sc, &e, &t, &s);
        if (t)
        {
            //printf("\tit's a type %d, %s, %s\n", t.ty, t.toChars(), t.deco);
            t = t.addMod(mtype.mod);
            if (mtype.isrvalue)
                t = t.rvalueOf();
            return t;
        }
        else
        {
            if (s)
            {
                auto td = s.isTemplateDeclaration;
                if (td && td.onemember && td.onemember.isAggregateDeclaration)
                    .error(loc, "template %s `%s` is used as a type without instantiation"
                        ~ "; to instantiate it use `%s!(arguments)`",
                        s.kind, s.toPrettyChars, s.ident.toChars);
                else
                    .error(loc, "%s `%s` is used as a type", s.kind, s.toPrettyChars);
                //assert(0);
            }
            else if (e.op == TOK.variable) // special case: variable is used as a type
            {
                Dsymbol varDecl = mtype.toDsymbol(sc);
                const(Loc) varDeclLoc = varDecl.getLoc();
                Module varDeclModule = varDecl.getModule();

                .error(loc, "variable `%s` is used as a type", mtype.toChars());

                if (varDeclModule != sc._module) // variable is imported
                {
                    const(Loc) varDeclModuleImportLoc = varDeclModule.getLoc();
                    .errorSupplemental(
                        varDeclModuleImportLoc,
                        "variable `%s` is imported here from: `%s`",
                        varDecl.toChars,
                        varDeclModule.toPrettyChars,
                    );
                }

                .errorSupplemental(varDeclLoc, "variable `%s` is declared here", varDecl.toChars);
            }
            else
                .error(loc, "`%s` is used as a type", mtype.toChars());
            return error();
        }
    }

    Type visitInstance(TypeInstance mtype)
    {
        Type t;
        Expression e;
        Dsymbol s;

        //printf("TypeInstance::semantic(%p, %s)\n", this, toChars());
        {
            const errors = global.errors;
            mtype.resolve(loc, sc, &e, &t, &s);
            // if we had an error evaluating the symbol, suppress further errors
            if (!t && errors != global.errors)
                return error();
        }

        if (!t)
        {
            if (!e && s && s.errors)
            {
                // if there was an error evaluating the symbol, it might actually
                // be a type. Avoid misleading error messages.
               .error(loc, "`%s` had previous errors", mtype.toChars());
            }
            else
               .error(loc, "`%s` is used as a type", mtype.toChars());
            return error();
        }
        return t;
    }

    Type visitTypeof(TypeTypeof mtype)
    {
        //printf("TypeTypeof::semantic() %s\n", toChars());
        Expression e;
        Type t;
        Dsymbol s;
        mtype.resolve(loc, sc, &e, &t, &s);
        if (s && (t = s.getType()) !is null)
        {
            t = t.addMod(mtype.mod);
            if (mtype.isrvalue)
                t = t.rvalueOf();
        }
        if (!t)
        {
            .error(loc, "`%s` is used as a type", mtype.toChars());
            return error();
        }
        return t;
    }

    Type visitTraits(TypeTraits mtype)
    {
        if (mtype.ty == Terror)
            return mtype;

        const inAlias = (sc.flags & SCOPE.alias_) != 0;
        if (mtype.exp.ident != Id.allMembers &&
            mtype.exp.ident != Id.derivedMembers &&
            mtype.exp.ident != Id.getMember &&
            mtype.exp.ident != Id.parent &&
            mtype.exp.ident != Id.getOverloads &&
            mtype.exp.ident != Id.getVirtualFunctions &&
            mtype.exp.ident != Id.getVirtualMethods &&
            mtype.exp.ident != Id.getAttributes &&
            mtype.exp.ident != Id.getUnitTests &&
            mtype.exp.ident != Id.getAliasThis)
        {
            static immutable (const(char)*)[2] ctxt = ["as type", "in alias"];
            .error(mtype.loc, "trait `%s` is either invalid or not supported %s",
                 mtype.exp.ident.toChars, ctxt[inAlias]);
            mtype.ty = Terror;
            return mtype;
        }

        import dmd.traits : semanticTraits;
        Type result;

        if (Expression e = semanticTraits(mtype.exp, sc))
        {
            switch (e.op)
            {
            case TOK.dotVariable:
                mtype.sym = (cast(DotVarExp)e).var;
                break;
            case TOK.variable:
                mtype.sym = (cast(VarExp)e).var;
                break;
            case TOK.function_:
                auto fe = cast(FuncExp)e;
                mtype.sym = fe.td ? fe.td : fe.fd;
                break;
            case TOK.dotTemplateDeclaration:
                mtype.sym = (cast(DotTemplateExp)e).td;
                break;
            case TOK.dSymbol:
                mtype.sym = (cast(DsymbolExp)e).s;
                break;
            case TOK.template_:
                mtype.sym = (cast(TemplateExp)e).td;
                break;
            case TOK.scope_:
                mtype.sym = (cast(ScopeExp)e).sds;
                break;
            case TOK.tuple:
                TupleExp te = e.toTupleExp();
                Objects* elems = new Objects(te.exps.dim);
                foreach (i; 0 .. elems.dim)
                {
                    auto src = (*te.exps)[i];
                    switch (src.op)
                    {
                    case TOK.type:
                        (*elems)[i] = (cast(TypeExp)src).type;
                        break;
                    case TOK.dotType:
                        (*elems)[i] = (cast(DotTypeExp)src).sym.isType();
                        break;
                    case TOK.overloadSet:
                        (*elems)[i] = (cast(OverExp)src).type;
                        break;
                    default:
                        if (auto sym = isDsymbol(src))
                            (*elems)[i] = sym;
                        else
                            (*elems)[i] = src;
                    }
                }
                TupleDeclaration td = new TupleDeclaration(e.loc, Identifier.generateId("__aliastup"), elems);
                mtype.sym = td;
                break;
            case TOK.dotType:
                result = (cast(DotTypeExp)e).sym.isType();
                break;
            case TOK.type:
                result = (cast(TypeExp)e).type;
                break;
            case TOK.overloadSet:
                result = (cast(OverExp)e).type;
                break;
            default:
                break;
            }
        }

        if (result)
            result = result.addMod(mtype.mod);
        if (!inAlias && !result)
        {
            if (!global.errors)
                .error(mtype.loc, "`%s` does not give a valid type", mtype.toChars);
            return error();
        }

        return result;
    }

    Type visitReturn(TypeReturn mtype)
    {
        //printf("TypeReturn::semantic() %s\n", toChars());
        Expression e;
        Type t;
        Dsymbol s;
        mtype.resolve(loc, sc, &e, &t, &s);
        if (s && (t = s.getType()) !is null)
        {
            t = t.addMod(mtype.mod);
            if (mtype.isrvalue)
                t = t.rvalueOf();
        }
        if (!t)
        {
            .error(loc, "`%s` is used as a type", mtype.toChars());
            return error();
        }
        return t;
    }

    Type visitStruct(TypeStruct mtype)
    {
        //printf("TypeStruct::semantic('%s')\n", mtype.toChars());
        if (mtype.deco)
        {
            if (sc && sc.cppmangle != CPPMANGLE.def)
            {
                if (mtype.cppmangle == CPPMANGLE.def)
                    mtype.cppmangle = sc.cppmangle;
            }
            return mtype;
        }

        /* Don't semantic for sym because it should be deferred until
         * sizeof needed or its members accessed.
         */
        // instead, parent should be set correctly
        assert(mtype.sym.parent);

        if (mtype.sym.type.ty == Terror)
            return error();

        if (sc && sc.cppmangle != CPPMANGLE.def)
            mtype.cppmangle = sc.cppmangle;
        else
            mtype.cppmangle = CPPMANGLE.asStruct;

        return merge(mtype);
    }

    Type visitEnum(TypeEnum mtype)
    {
        //printf("TypeEnum::semantic() %s\n", toChars());
        return mtype.deco ? mtype : merge(mtype);
    }

    Type visitClass(TypeClass mtype)
    {
        //printf("TypeClass::semantic(%s)\n", mtype.toChars());
        if (mtype.deco)
        {
            if (sc && sc.cppmangle != CPPMANGLE.def)
            {
                if (mtype.cppmangle == CPPMANGLE.def)
                    mtype.cppmangle = sc.cppmangle;
            }
            return mtype;
        }

        /* Don't semantic for sym because it should be deferred until
         * sizeof needed or its members accessed.
         */
        // instead, parent should be set correctly
        assert(mtype.sym.parent);

        if (mtype.sym.type.ty == Terror)
            return error();

        if (sc && sc.cppmangle != CPPMANGLE.def)
            mtype.cppmangle = sc.cppmangle;
        else
            mtype.cppmangle = CPPMANGLE.asClass;

        return merge(mtype);
    }

    Type visitTuple(TypeTuple mtype)
    {
        //printf("TypeTuple::semantic(this = %p)\n", this);
        //printf("TypeTuple::semantic() %p, %s\n", this, toChars());
        if (!mtype.deco)
            mtype.deco = merge(mtype).deco;

        /* Don't return merge(), because a tuple with one type has the
         * same deco as that type.
         */
        return mtype;
    }

    Type visitSlice(TypeSlice mtype)
    {
        //printf("TypeSlice::semantic() %s\n", toChars());
        Type tn = mtype.next.typeSemantic(loc, sc);
        //printf("next: %s\n", tn.toChars());

        Type tbn = tn.toBasetype();
        if (tbn.ty != Ttuple)
        {
            .error(loc, "can only slice tuple types, not `%s`", tbn.toChars());
            return error();
        }
        TypeTuple tt = cast(TypeTuple)tbn;

        mtype.lwr = semanticLength(sc, tbn, mtype.lwr);
        mtype.upr = semanticLength(sc, tbn, mtype.upr);
        mtype.lwr = mtype.lwr.ctfeInterpret();
        mtype.upr = mtype.upr.ctfeInterpret();
        if (mtype.lwr.op == TOK.error || mtype.upr.op == TOK.error)
            return error();

        uinteger_t i1 = mtype.lwr.toUInteger();
        uinteger_t i2 = mtype.upr.toUInteger();
        if (!(i1 <= i2 && i2 <= tt.arguments.dim))
        {
            .error(loc, "slice `[%llu..%llu]` is out of range of `[0..%llu]`",
                cast(ulong)i1, cast(ulong)i2, cast(ulong)tt.arguments.dim);
            return error();
        }

        mtype.next = tn;
        mtype.transitive();

        auto args = new Parameters();
        args.reserve(cast(size_t)(i2 - i1));
        foreach (arg; (*tt.arguments)[cast(size_t)i1 .. cast(size_t)i2])
        {
            args.push(arg);
        }
        Type t = new TypeTuple(args);
        return t.typeSemantic(loc, sc);
    }

    Type visitMixin(TypeMixin mtype)
    {
        //printf("TypeMixin::semantic() %s\n", toChars());
        Type t = mtype.compileTypeMixin(loc, sc);
        if (!t)
            return error();

        return t.typeSemantic(loc, sc);
    }

    switch (t.ty)
    {
        default:         return visitType(t);
        case Tvector:    return visitVector(cast(TypeVector)t);
        case Tsarray:    return visitSArray(cast(TypeSArray)t);
        case Tarray:     return visitDArray(cast(TypeDArray)t);
        case Taarray:    return visitAArray(cast(TypeAArray)t);
        case Tpointer:   return visitPointer(cast(TypePointer)t);
        case Treference: return visitReference(cast(TypeReference)t);
        case Tfunction:  return visitFunction(cast(TypeFunction)t);
        case Tdelegate:  return visitDelegate(cast(TypeDelegate)t);
        case Tident:     return visitIdentifier(cast(TypeIdentifier)t);
        case Tinstance:  return visitInstance(cast(TypeInstance)t);
        case Ttypeof:    return visitTypeof(cast(TypeTypeof)t);
        case Ttraits:    return visitTraits(cast(TypeTraits)t);
        case Treturn:    return visitReturn(cast(TypeReturn)t);
        case Tstruct:    return visitStruct(cast(TypeStruct)t);
        case Tenum:      return visitEnum(cast(TypeEnum)t);
        case Tclass:     return visitClass(cast(TypeClass)t);
        case Ttuple:     return visitTuple (cast(TypeTuple)t);
        case Tslice:     return visitSlice(cast(TypeSlice)t);
        case Tmixin:     return visitMixin(cast(TypeMixin)t);
    }
}

/******************************************
 * Compile the MixinType, returning the type AST.
 *
 * Doesn't run semantic() on the returned type.
 * Params:
 *      tm = mixin to compile as a type
 *      loc = location for error messages
 *      sc = context
 * Return:
 *      null if error, else type AST as parsed
 */
Type compileTypeMixin(TypeMixin tm, Loc loc, Scope* sc)
{
    OutBuffer buf;
    if (expressionsToString(buf, sc, tm.exps))
        return null;

    const errors = global.errors;
    const len = buf.length;
    const str = buf.extractChars()[0 .. len];
    scope diagnosticReporter = new StderrDiagnosticReporter(global.params.useDeprecated);
    scope p = new Parser!ASTCodegen(loc, sc._module, str, false, diagnosticReporter);
    p.nextToken();
    //printf("p.loc.linnum = %d\n", p.loc.linnum);

    Type t = p.parseType();
    if (p.errors)
    {
        assert(global.errors != errors); // should have caught all these cases
        return null;
    }
    if (p.token.value != TOK.endOfFile)
    {
        .error(loc, "incomplete mixin type `%s`", str.ptr);
        return null;
    }
    return t;
}


/************************************
 * If an identical type to `type` is in `type.stringtable`, return
 * the latter one. Otherwise, add it to `type.stringtable`.
 * Some types don't get merged and are returned as-is.
 * Params:
 *      type = Type to check against existing types
 * Returns:
 *      the type that was merged
 */
Type merge(Type type)
{
    switch (type.ty)
    {
        case Terror:
        case Ttypeof:
        case Tident:
        case Tinstance:
        case Tmixin:
            return type;

        case Tsarray:
            // prevents generating the mangle if the array dim is not yet known
            if (!(cast(TypeSArray) type).dim.isIntegerExp())
                return type;
            goto default;

        case Tenum:
            break;

        case Taarray:
            if (!(cast(TypeAArray)type).index.merge().deco)
                return type;
            goto default;

        default:
            if (type.nextOf() && !type.nextOf().deco)
                return type;
            break;
    }

    //printf("merge(%s)\n", toChars());
    if (!type.deco)
    {
        OutBuffer buf;
        buf.reserve(32);

        mangleToBuffer(type, &buf);

        StringValue* sv = type.stringtable.update(buf.peekSlice());
        if (sv.ptrvalue)
        {
            Type t = cast(Type)sv.ptrvalue;
            debug
            {
                import core.stdc.stdio;
                if (!t.deco)
                    printf("t = %s\n", t.toChars());
            }
            assert(t.deco);
            //printf("old value, deco = '%s' %p\n", t.deco, t.deco);
            return t;
        }
        else
        {
            Type t = stripDefaultArgs(type);
            sv.ptrvalue = cast(char*)t;
            type.deco = t.deco = cast(char*)sv.toDchars();
            //printf("new value, deco = '%s' %p\n", t.deco, t.deco);
            return t;
        }
    }
    return type;
}

/***************************************
 * Calculate built-in properties which just the type is necessary.
 *
 * Params:
 *  t = the type for which the property is calculated
 *  loc = the location where the property is encountered
 *  ident = the identifier of the property
 *  flag = if flag & 1, don't report "not a property" error and just return NULL.
 * Returns:
 *      expression representing the property, or null if not a property and (flag & 1)
 */
Expression getProperty(Type t, const ref Loc loc, Identifier ident, int flag)
{
    Expression visitType(Type mt)
    {
        Expression e;
        static if (LOGDOTEXP)
        {
            printf("Type::getProperty(type = '%s', ident = '%s')\n", mt.toChars(), ident.toChars());
        }
        if (ident == Id.__sizeof)
        {
            d_uns64 sz = mt.size(loc);
            if (sz == SIZE_INVALID)
                return new ErrorExp();
            e = new IntegerExp(loc, sz, Type.tsize_t);
        }
        else if (ident == Id.__xalignof)
        {
            const explicitAlignment = mt.alignment();
            const naturalAlignment = mt.alignsize();
            const actualAlignment = (explicitAlignment == STRUCTALIGN_DEFAULT ? naturalAlignment : explicitAlignment);
            e = new IntegerExp(loc, actualAlignment, Type.tsize_t);
        }
        else if (ident == Id._init)
        {
            Type tb = mt.toBasetype();
            e = mt.defaultInitLiteral(loc);
            if (tb.ty == Tstruct && tb.needsNested())
            {
                e.isStructLiteralExp().useStaticInit = true;
            }
        }
        else if (ident == Id._mangleof)
        {
            if (!mt.deco)
            {
                error(loc, "forward reference of type `%s.mangleof`", mt.toChars());
                e = new ErrorExp();
            }
            else
            {
                e = new StringExp(loc, mt.deco);
                Scope sc;
                e = e.expressionSemantic(&sc);
            }
        }
        else if (ident == Id.stringof)
        {
            const s = mt.toChars();
            e = new StringExp(loc, cast(char*)s);
            Scope sc;
            e = e.expressionSemantic(&sc);
        }
        else if (flag && mt != Type.terror)
        {
            return null;
        }
        else
        {
            Dsymbol s = null;
            if (mt.ty == Tstruct || mt.ty == Tclass || mt.ty == Tenum)
                s = mt.toDsymbol(null);
            if (s)
                s = s.search_correct(ident);
            if (mt != Type.terror)
            {
                if (s)
                    error(loc, "no property `%s` for type `%s`, did you mean `%s`?", ident.toChars(), mt.toChars(), s.toPrettyChars());
                else
                {
                    if (ident == Id.call && mt.ty == Tclass)
                        error(loc, "no property `%s` for type `%s`, did you mean `new %s`?", ident.toChars(), mt.toChars(), mt.toPrettyChars());
                    else
                    {
                        if (const n = importHint(ident.toString()))
                            error(loc, "no property `%s` for type `%s`, perhaps `import %.*s;` is needed?", ident.toChars(), mt.toChars(), cast(int)n.length, n.ptr);
                        else
                            error(loc, "no property `%s` for type `%s`", ident.toChars(), mt.toChars());
                    }
                }
            }
            e = new ErrorExp();
        }
        return e;
    }

    Expression visitError(TypeError)
    {
        return new ErrorExp();
    }

    Expression visitBasic(TypeBasic mt)
    {
        Expression integerValue(dinteger_t i)
        {
            return new IntegerExp(loc, i, mt);
        }

        Expression intValue(dinteger_t i)
        {
            return new IntegerExp(loc, i, Type.tint32);
        }

        Expression floatValue(real_t r)
        {
            if (mt.isreal() || mt.isimaginary())
                return new RealExp(loc, r, mt);
            else
            {
                return new ComplexExp(loc, complex_t(r, r), mt);
            }
        }

        //printf("TypeBasic::getProperty('%s')\n", ident.toChars());
        if (ident == Id.max)
        {
            switch (mt.ty)
            {
            case Tint8:        return integerValue(byte.max);
            case Tuns8:        return integerValue(ubyte.max);
            case Tint16:       return integerValue(short.max);
            case Tuns16:       return integerValue(ushort.max);
            case Tint32:       return integerValue(int.max);
            case Tuns32:       return integerValue(uint.max);
            case Tint64:       return integerValue(long.max);
            case Tuns64:       return integerValue(ulong.max);
            case Tbool:        return integerValue(bool.max);
            case Tchar:        return integerValue(char.max);
            case Twchar:       return integerValue(wchar.max);
            case Tdchar:       return integerValue(dchar.max);
            case Tcomplex32:
            case Timaginary32:
            case Tfloat32:     return floatValue(target.FloatProperties.max);
            case Tcomplex64:
            case Timaginary64:
            case Tfloat64:     return floatValue(target.DoubleProperties.max);
            case Tcomplex80:
            case Timaginary80:
            case Tfloat80:     return floatValue(target.RealProperties.max);
            default:           break;
            }
        }
        else if (ident == Id.min)
        {
            switch (mt.ty)
            {
            case Tint8:        return integerValue(byte.min);
            case Tuns8:
            case Tuns16:
            case Tuns32:
            case Tuns64:
            case Tbool:
            case Tchar:
            case Twchar:
            case Tdchar:       return integerValue(0);
            case Tint16:       return integerValue(short.min);
            case Tint32:       return integerValue(int.min);
            case Tint64:       return integerValue(long.min);
            default:           break;
            }
        }
        else if (ident == Id.min_normal)
        {
            switch (mt.ty)
            {
            case Tcomplex32:
            case Timaginary32:
            case Tfloat32:     return floatValue(target.FloatProperties.min_normal);
            case Tcomplex64:
            case Timaginary64:
            case Tfloat64:     return floatValue(target.DoubleProperties.min_normal);
            case Tcomplex80:
            case Timaginary80:
            case Tfloat80:     return floatValue(target.RealProperties.min_normal);
            default:           break;
            }
        }
        else if (ident == Id.nan)
        {
            switch (mt.ty)
            {
            case Tcomplex32:
            case Tcomplex64:
            case Tcomplex80:
            case Timaginary32:
            case Timaginary64:
            case Timaginary80:
            case Tfloat32:
            case Tfloat64:
            case Tfloat80:     return floatValue(target.RealProperties.nan);
            default:           break;
            }
        }
        else if (ident == Id.infinity)
        {
            switch (mt.ty)
            {
            case Tcomplex32:
            case Tcomplex64:
            case Tcomplex80:
            case Timaginary32:
            case Timaginary64:
            case Timaginary80:
            case Tfloat32:
            case Tfloat64:
            case Tfloat80:     return floatValue(target.RealProperties.infinity);
            default:           break;
            }
        }
        else if (ident == Id.dig)
        {
            switch (mt.ty)
            {
            case Tcomplex32:
            case Timaginary32:
            case Tfloat32:     return intValue(target.FloatProperties.dig);
            case Tcomplex64:
            case Timaginary64:
            case Tfloat64:     return intValue(target.DoubleProperties.dig);
            case Tcomplex80:
            case Timaginary80:
            case Tfloat80:     return intValue(target.RealProperties.dig);
            default:           break;
            }
        }
        else if (ident == Id.epsilon)
        {
            switch (mt.ty)
            {
            case Tcomplex32:
            case Timaginary32:
            case Tfloat32:     return floatValue(target.FloatProperties.epsilon);
            case Tcomplex64:
            case Timaginary64:
            case Tfloat64:     return floatValue(target.DoubleProperties.epsilon);
            case Tcomplex80:
            case Timaginary80:
            case Tfloat80:     return floatValue(target.RealProperties.epsilon);
            default:           break;
            }
        }
        else if (ident == Id.mant_dig)
        {
            switch (mt.ty)
            {
            case Tcomplex32:
            case Timaginary32:
            case Tfloat32:     return intValue(target.FloatProperties.mant_dig);
            case Tcomplex64:
            case Timaginary64:
            case Tfloat64:     return intValue(target.DoubleProperties.mant_dig);
            case Tcomplex80:
            case Timaginary80:
            case Tfloat80:     return intValue(target.RealProperties.mant_dig);
            default:           break;
            }
        }
        else if (ident == Id.max_10_exp)
        {
            switch (mt.ty)
            {
            case Tcomplex32:
            case Timaginary32:
            case Tfloat32:     return intValue(target.FloatProperties.max_10_exp);
            case Tcomplex64:
            case Timaginary64:
            case Tfloat64:     return intValue(target.DoubleProperties.max_10_exp);
            case Tcomplex80:
            case Timaginary80:
            case Tfloat80:     return intValue(target.RealProperties.max_10_exp);
            default:           break;
            }
        }
        else if (ident == Id.max_exp)
        {
            switch (mt.ty)
            {
            case Tcomplex32:
            case Timaginary32:
            case Tfloat32:     return intValue(target.FloatProperties.max_exp);
            case Tcomplex64:
            case Timaginary64:
            case Tfloat64:     return intValue(target.DoubleProperties.max_exp);
            case Tcomplex80:
            case Timaginary80:
            case Tfloat80:     return intValue(target.RealProperties.max_exp);
            default:           break;
            }
        }
        else if (ident == Id.min_10_exp)
        {
            switch (mt.ty)
            {
            case Tcomplex32:
            case Timaginary32:
            case Tfloat32:     return intValue(target.FloatProperties.min_10_exp);
            case Tcomplex64:
            case Timaginary64:
            case Tfloat64:     return intValue(target.DoubleProperties.min_10_exp);
            case Tcomplex80:
            case Timaginary80:
            case Tfloat80:     return intValue(target.RealProperties.min_10_exp);
            default:           break;
            }
        }
        else if (ident == Id.min_exp)
        {
            switch (mt.ty)
            {
            case Tcomplex32:
            case Timaginary32:
            case Tfloat32:     return intValue(target.FloatProperties.min_exp);
            case Tcomplex64:
            case Timaginary64:
            case Tfloat64:     return intValue(target.DoubleProperties.min_exp);
            case Tcomplex80:
            case Timaginary80:
            case Tfloat80:     return intValue(target.RealProperties.min_exp);
            default:           break;
            }
        }
        return visitType(mt);
    }

    Expression visitVector(TypeVector mt)
    {
        return visitType(mt);
    }

    Expression visitEnum(TypeEnum mt)
    {
        Expression e;
        if (ident == Id.max || ident == Id.min)
        {
            return mt.sym.getMaxMinValue(loc, ident);
        }
        else if (ident == Id._init)
        {
            e = mt.defaultInitLiteral(loc);
        }
        else if (ident == Id.stringof)
        {
            const s = mt.toChars();
            e = new StringExp(loc, cast(char*)s);
            Scope sc;
            e = e.expressionSemantic(&sc);
        }
        else if (ident == Id._mangleof)
        {
            e = visitType(mt);
        }
        else
        {
            e = mt.toBasetype().getProperty(loc, ident, flag);
        }
        return e;
    }

    Expression visitTuple(TypeTuple mt)
    {
        Expression e;
        static if (LOGDOTEXP)
        {
            printf("TypeTuple::getProperty(type = '%s', ident = '%s')\n", mt.toChars(), ident.toChars());
        }
        if (ident == Id.length)
        {
            e = new IntegerExp(loc, mt.arguments.dim, Type.tsize_t);
        }
        else if (ident == Id._init)
        {
            e = mt.defaultInitLiteral(loc);
        }
        else if (flag)
        {
            e = null;
        }
        else
        {
            error(loc, "no property `%s` for tuple `%s`", ident.toChars(), mt.toChars());
            e = new ErrorExp();
        }
        return e;
    }

    switch (t.ty)
    {
        default:        return t.isTypeBasic() ?
                                visitBasic(cast(TypeBasic)t) :
                                visitType(t);

        case Terror:    return visitError (cast(TypeError)t);
        case Tvector:   return visitVector(cast(TypeVector)t);
        case Tenum:     return visitEnum  (cast(TypeEnum)t);
        case Ttuple:    return visitTuple (cast(TypeTuple)t);
    }
}

/***************************************
 * Normalize `e` as the result of resolve() process.
 */
private void resolveExp(Expression e, Type *pt, Expression *pe, Dsymbol* ps)
{
    *pt = null;
    *pe = null;
    *ps = null;

    Dsymbol s;
    switch (e.op)
    {
        case TOK.error:
            *pt = Type.terror;
            return;

        case TOK.type:
            *pt = e.type;
            return;

        case TOK.variable:
            s = (cast(VarExp)e).var;
            if (s.isVarDeclaration())
                goto default;
            //if (s.isOverDeclaration())
            //    todo;
            break;

        case TOK.template_:
            // TemplateDeclaration
            s = (cast(TemplateExp)e).td;
            break;

        case TOK.scope_:
            s = (cast(ScopeExp)e).sds;
            // TemplateDeclaration, TemplateInstance, Import, Package, Module
            break;

        case TOK.function_:
            s = getDsymbol(e);
            break;

        case TOK.dotTemplateDeclaration:
            s = (cast(DotTemplateExp)e).td;
            break;

        //case TOK.this_:
        //case TOK.super_:

        //case TOK.tuple:

        //case TOK.overloadSet:

        //case TOK.dotVariable:
        //case TOK.dotTemplateInstance:
        //case TOK.dotType:
        //case TOK.dotIdentifier:

        default:
            *pe = e;
            return;
    }

    *ps = s;
}

/************************************
 * Resolve type 'mt' to either type, symbol, or expression.
 * If errors happened, resolved to Type.terror.
 *
 * Params:
 *  mt = type to be resolved
 *  loc = the location where the type is encountered
 *  sc = the scope of the type
 *  pe = is set if t is an expression
 *  pt = is set if t is a type
 *  ps = is set if t is a symbol
 *  intypeid = true if in type id
 */
void resolve(Type mt, const ref Loc loc, Scope* sc, Expression* pe, Type* pt, Dsymbol* ps, bool intypeid = false)
{
    void returnExp(Expression e)
    {
        *pt = null;
        *pe = e;
        *ps = null;
    }

    void returnType(Type t)
    {
        *pt = t;
        *pe = null;
        *ps = null;
    }

    void returnSymbol(Dsymbol s)
    {
        *pt = null;
        *pe = null;
        *ps = s;
    }

    void returnError()
    {
        returnType(Type.terror);
    }

    void visitType(Type mt)
    {
        //printf("Type::resolve() %s, %d\n", mt.toChars(), mt.ty);
        Type t = typeSemantic(mt, loc, sc);
        assert(t);
        returnType(t);
    }

    void visitSArray(TypeSArray mt)
    {
        //printf("TypeSArray::resolve() %s\n", mt.toChars());
        mt.next.resolve(loc, sc, pe, pt, ps, intypeid);
        //printf("s = %p, e = %p, t = %p\n", *ps, *pe, *pt);
        if (*pe)
        {
            // It's really an index expression
            if (Dsymbol s = getDsymbol(*pe))
                *pe = new DsymbolExp(loc, s);
            returnExp(new ArrayExp(loc, *pe, mt.dim));
        }
        else if (*ps)
        {
            Dsymbol s = *ps;
            if (auto tup = s.isTupleDeclaration())
            {
                mt.dim = semanticLength(sc, tup, mt.dim);
                mt.dim = mt.dim.ctfeInterpret();
                if (mt.dim.op == TOK.error)
                    return returnError();

                const d = mt.dim.toUInteger();
                if (d >= tup.objects.dim)
                {
                    error(loc, "tuple index `%llu` exceeds length %u", d, tup.objects.dim);
                    return returnError();
                }

                RootObject o = (*tup.objects)[cast(size_t)d];
                if (o.dyncast() == DYNCAST.dsymbol)
                {
                    return returnSymbol(cast(Dsymbol)o);
                }
                if (o.dyncast() == DYNCAST.expression)
                {
                    Expression e = cast(Expression)o;
                    if (e.op == TOK.dSymbol)
                        return returnSymbol((cast(DsymbolExp)e).s);
                    else
                        return returnExp(e);
                }
                if (o.dyncast() == DYNCAST.type)
                {
                    return returnType((cast(Type)o).addMod(mt.mod));
                }

                /* Create a new TupleDeclaration which
                 * is a slice [d..d+1] out of the old one.
                 * Do it this way because TemplateInstance::semanticTiargs()
                 * can handle unresolved Objects this way.
                 */
                auto objects = new Objects(1);
                (*objects)[0] = o;
                return returnSymbol(new TupleDeclaration(loc, tup.ident, objects));
            }
            else
                return visitType(mt);
        }
        else
        {
            if ((*pt).ty != Terror)
                mt.next = *pt; // prevent re-running semantic() on 'next'
            visitType(mt);
        }

    }

    void visitDArray(TypeDArray mt)
    {
        //printf("TypeDArray::resolve() %s\n", mt.toChars());
        mt.next.resolve(loc, sc, pe, pt, ps, intypeid);
        //printf("s = %p, e = %p, t = %p\n", *ps, *pe, *pt);
        if (*pe)
        {
            // It's really a slice expression
            if (Dsymbol s = getDsymbol(*pe))
                *pe = new DsymbolExp(loc, s);
            returnExp(new ArrayExp(loc, *pe));
        }
        else if (*ps)
        {
            if (auto tup = (*ps).isTupleDeclaration())
            {
                // keep *ps
            }
            else
                visitType(mt);
        }
        else
        {
            if ((*pt).ty != Terror)
                mt.next = *pt; // prevent re-running semantic() on 'next'
            visitType(mt);
        }
    }

    void visitAArray(TypeAArray mt)
    {
        //printf("TypeAArray::resolve() %s\n", mt.toChars());
        // Deal with the case where we thought the index was a type, but
        // in reality it was an expression.
        if (mt.index.ty == Tident || mt.index.ty == Tinstance || mt.index.ty == Tsarray)
        {
            Expression e;
            Type t;
            Dsymbol s;
            mt.index.resolve(loc, sc, &e, &t, &s, intypeid);
            if (e)
            {
                // It was an expression -
                // Rewrite as a static array
                auto tsa = new TypeSArray(mt.next, e);
                tsa.mod = mt.mod; // just copy mod field so tsa's semantic is not yet done
                return tsa.resolve(loc, sc, pe, pt, ps, intypeid);
            }
            else if (t)
                mt.index = t;
            else
                .error(loc, "index is not a type or an expression");
        }
        visitType(mt);
    }

    /*************************************
     * Takes an array of Identifiers and figures out if
     * it represents a Type or an Expression.
     * Output:
     *      if expression, *pe is set
     *      if type, *pt is set
     */
    void visitIdentifier(TypeIdentifier mt)
    {
        //printf("TypeIdentifier::resolve(sc = %p, idents = '%s')\n", sc, mt.toChars());
        if ((mt.ident.equals(Id._super) || mt.ident.equals(Id.This)) && !hasThis(sc))
        {
            // @@@DEPRECATED_v2.091@@@.
            // Made an error in 2.086.
            // Eligible for removal in 2.091.
            if (mt.ident.equals(Id._super))
            {
                error(mt.loc, "Using `super` as a type is obsolete. Use `typeof(super)` instead");
            }
             // @@@DEPRECATED_v2.091@@@.
            // Made an error in 2.086.
            // Eligible for removal in 2.091.
            if (mt.ident.equals(Id.This))
            {
                error(mt.loc, "Using `this` as a type is obsolete. Use `typeof(this)` instead");
            }
            if (AggregateDeclaration ad = sc.getStructClassScope())
            {
                if (ClassDeclaration cd = ad.isClassDeclaration())
                {
                    if (mt.ident.equals(Id.This))
                        mt.ident = cd.ident;
                    else if (cd.baseClass && mt.ident.equals(Id._super))
                        mt.ident = cd.baseClass.ident;
                }
                else
                {
                    StructDeclaration sd = ad.isStructDeclaration();
                    if (sd && mt.ident.equals(Id.This))
                        mt.ident = sd.ident;
                }
            }
        }
        if (mt.ident == Id.ctfe)
        {
            error(loc, "variable `__ctfe` cannot be read at compile time");
            return returnError();
        }

        Dsymbol scopesym;
        Dsymbol s = sc.search(loc, mt.ident, &scopesym);
        /*
         * https://issues.dlang.org/show_bug.cgi?id=1170
         * https://issues.dlang.org/show_bug.cgi?id=10739
         *
         * If a symbol is not found, it might be declared in
         * a mixin-ed string or a mixin-ed template, so before
         * issuing an error semantically analyze all string/template
         * mixins that are members of the current ScopeDsymbol.
         */
        if (!s && sc.enclosing)
        {
            ScopeDsymbol sds = sc.enclosing.scopesym;
            if (sds && sds.members)
            {
                void semanticOnMixin(Dsymbol member)
                {
                    if (auto compileDecl = member.isCompileDeclaration())
                        compileDecl.dsymbolSemantic(sc);
                    else if (auto mixinTempl = member.isTemplateMixin())
                        mixinTempl.dsymbolSemantic(sc);
                }
                sds.members.foreachDsymbol( s => semanticOnMixin(s) );
                s = sc.search(loc, mt.ident, &scopesym);
            }
        }

        if (s)
        {
            // https://issues.dlang.org/show_bug.cgi?id=16042
            // If `f` is really a function template, then replace `f`
            // with the function template declaration.
            if (auto f = s.isFuncDeclaration())
            {
                if (auto td = getFuncTemplateDecl(f))
                {
                    // If not at the beginning of the overloaded list of
                    // `TemplateDeclaration`s, then get the beginning
                    if (td.overroot)
                        td = td.overroot;
                    s = td;
                }
            }
        }

        mt.resolveHelper(loc, sc, s, scopesym, pe, pt, ps, intypeid);
        if (*pt)
        {
            (*pt) = (*pt).addMod(mt.mod);
            if (mt.isrvalue)
                (*pt) = (*pt).rvalueOf();
        }
    }

    void visitInstance(TypeInstance mt)
    {
        // Note close similarity to TypeIdentifier::resolve()

        //printf("TypeInstance::resolve(sc = %p, tempinst = '%s')\n", sc, mt.tempinst.toChars());
        mt.tempinst.dsymbolSemantic(sc);
        if (!global.gag && mt.tempinst.errors)
            return returnError();

        mt.resolveHelper(loc, sc, mt.tempinst, null, pe, pt, ps, intypeid);
        if (*pt)
        {
            *pt = (*pt).addMod(mt.mod);
            if (mt.isrvalue)
                (*pt) = (*pt).rvalueOf();
        }
        //if (*pt) printf("*pt = %d '%s'\n", (*pt).ty, (*pt).toChars());
    }

    void visitTypeof(TypeTypeof mt)
    {
        //printf("TypeTypeof::resolve(this = %p, sc = %p, idents = '%s')\n", mt, sc, mt.toChars());
        //static int nest; if (++nest == 50) *(char*)0=0;
        if (sc is null)
        {
            error(loc, "Invalid scope.");
            return returnError();
        }
        if (mt.inuse)
        {
            mt.inuse = 2;
            error(loc, "circular `typeof` definition");
        Lerr:
            mt.inuse--;
            return returnError();
        }
        mt.inuse++;

        /* Currently we cannot evaluate 'exp' in speculative context, because
         * the type implementation may leak to the final execution. Consider:
         *
         * struct S(T) {
         *   string toString() const { return "x"; }
         * }
         * void main() {
         *   alias X = typeof(S!int());
         *   assert(typeid(X).toString() == "x");
         * }
         */
        Scope* sc2 = sc.push();
        sc2.intypeof = 1;
        auto exp2 = mt.exp.expressionSemantic(sc2);
        exp2 = resolvePropertiesOnly(sc2, exp2);
        sc2.pop();

        if (exp2.op == TOK.error)
        {
            if (!global.gag)
                mt.exp = exp2;
            goto Lerr;
        }
        mt.exp = exp2;

        if (mt.exp.op == TOK.type ||
            mt.exp.op == TOK.scope_)
        {
            if (mt.exp.checkType())
                goto Lerr;

            /* Today, 'typeof(func)' returns void if func is a
             * function template (TemplateExp), or
             * template lambda (FuncExp).
             * It's actually used in Phobos as an idiom, to branch code for
             * template functions.
             */
        }
        if (auto f = mt.exp.op == TOK.variable    ? (cast(   VarExp)mt.exp).var.isFuncDeclaration()
                   : mt.exp.op == TOK.dotVariable ? (cast(DotVarExp)mt.exp).var.isFuncDeclaration() : null)
        {
            if (f.checkForwardRef(loc))
                goto Lerr;
        }
        if (auto f = isFuncAddress(mt.exp))
        {
            if (f.checkForwardRef(loc))
                goto Lerr;
        }

        Type t = mt.exp.type;
        if (!t)
        {
            error(loc, "expression `%s` has no type", mt.exp.toChars());
            goto Lerr;
        }
        if (t.ty == Ttypeof)
        {
            error(loc, "forward reference to `%s`", mt.toChars());
            goto Lerr;
        }
        if (mt.idents.dim == 0)
        {
            t = t.addMod(mt.mod);
            if (mt.isrvalue)
                t = t.rvalueOf();
            returnType(t);
        }
        else
        {
            if (Dsymbol s = t.toDsymbol(sc))
                mt.resolveHelper(loc, sc, s, null, pe, pt, ps, intypeid);
            else
            {
                auto e = typeToExpressionHelper(mt, new TypeExp(loc, t));
                e = e.expressionSemantic(sc);
                resolveExp(e, pt, pe, ps);
            }
            if (*pt)
            {
                (*pt) = (*pt).addMod(mt.mod);
                if (mt.isrvalue)
                    (*pt) = (*pt).rvalueOf();
            }
        }
        mt.inuse--;
    }

    void visitReturn(TypeReturn mt)
    {
        //printf("TypeReturn::resolve(sc = %p, idents = '%s')\n", sc, mt.toChars());
        Type t;
        {
            FuncDeclaration func = sc.func;
            if (!func)
            {
                error(loc, "`typeof(return)` must be inside function");
                return returnError();
            }
            if (func.fes)
                func = func.fes.func;
            t = func.type.nextOf();
            if (!t)
            {
                error(loc, "cannot use `typeof(return)` inside function `%s` with inferred return type", sc.func.toChars());
                return returnError();
            }
        }
        if (mt.idents.dim == 0)
        {
            t = t.addMod(mt.mod);
            if (mt.isrvalue)
                t = t.rvalueOf();
            return returnType(t);
        }
        else
        {
            if (Dsymbol s = t.toDsymbol(sc))
                mt.resolveHelper(loc, sc, s, null, pe, pt, ps, intypeid);
            else
            {
                auto e = typeToExpressionHelper(mt, new TypeExp(loc, t));
                e = e.expressionSemantic(sc);
                resolveExp(e, pt, pe, ps);
            }
            if (*pt)
            {
                (*pt) = (*pt).addMod(mt.mod);
                if (mt.isrvalue)
                    (*pt) = (*pt).rvalueOf();
            }
        }
    }

    void visitSlice(TypeSlice mt)
    {
        mt.next.resolve(loc, sc, pe, pt, ps, intypeid);
        if (*pe)
        {
            // It's really a slice expression
            if (Dsymbol s = getDsymbol(*pe))
                *pe = new DsymbolExp(loc, s);
            return returnExp(new ArrayExp(loc, *pe, new IntervalExp(loc, mt.lwr, mt.upr)));
        }
        else if (*ps)
        {
            Dsymbol s = *ps;
            TupleDeclaration td = s.isTupleDeclaration();
            if (td)
            {
                /* It's a slice of a TupleDeclaration
                 */
                ScopeDsymbol sym = new ArrayScopeSymbol(sc, td);
                sym.parent = sc.scopesym;
                sc = sc.push(sym);
                sc = sc.startCTFE();
                mt.lwr = mt.lwr.expressionSemantic(sc);
                mt.upr = mt.upr.expressionSemantic(sc);
                sc = sc.endCTFE();
                sc = sc.pop();

                mt.lwr = mt.lwr.ctfeInterpret();
                mt.upr = mt.upr.ctfeInterpret();
                const i1 = mt.lwr.toUInteger();
                const i2 = mt.upr.toUInteger();
                if (!(i1 <= i2 && i2 <= td.objects.dim))
                {
                    error(loc, "slice `[%llu..%llu]` is out of range of [0..%u]", i1, i2, td.objects.dim);
                    return returnError();
                }

                if (i1 == 0 && i2 == td.objects.dim)
                {
                    return returnSymbol(td);
                }

                /* Create a new TupleDeclaration which
                 * is a slice [i1..i2] out of the old one.
                 */
                auto objects = new Objects(cast(size_t)(i2 - i1));
                for (size_t i = 0; i < objects.dim; i++)
                {
                    (*objects)[i] = (*td.objects)[cast(size_t)i1 + i];
                }

                return returnSymbol(new TupleDeclaration(loc, td.ident, objects));
            }
            else
                visitType(mt);
        }
        else
        {
            if ((*pt).ty != Terror)
                mt.next = *pt; // prevent re-running semantic() on 'next'
            visitType(mt);
        }
    }

    void visitMixin(TypeMixin mt)
    {
        auto ta = mt.compileTypeMixin(loc, sc);
        if (ta)
        {
            auto tt = ta.isTypeTraits();
            if (tt && tt.exp)
            {
                *pe = tt.exp;
            }
            else
                resolve(ta, loc, sc, pe, pt, ps, intypeid);
        }
        else
            returnError();
    }

    void visitTraits(TypeTraits tt)
    {
        if (Type t = typeSemantic(tt, loc, sc))
            returnType(t);
        else if (tt.sym)
            returnSymbol(tt.sym);
        else
            return returnError();
    }

    switch (mt.ty)
    {
        default:        visitType      (mt);                     break;
        case Tsarray:   visitSArray    (cast(TypeSArray)mt);     break;
        case Tarray:    visitDArray    (cast(TypeDArray)mt);     break;
        case Taarray:   visitAArray    (cast(TypeAArray)mt);     break;
        case Tident:    visitIdentifier(cast(TypeIdentifier)mt); break;
        case Tinstance: visitInstance  (cast(TypeInstance)mt);   break;
        case Ttypeof:   visitTypeof    (cast(TypeTypeof)mt);     break;
        case Treturn:   visitReturn    (cast(TypeReturn)mt);     break;
        case Tslice:    visitSlice     (cast(TypeSlice)mt);      break;
        case Tmixin:    visitMixin     (cast(TypeMixin)mt);      break;
        case Ttraits:   visitTraits    (cast(TypeTraits)mt);     break;
    }
}

/************************
 * Access the members of the object e. This type is same as e.type.
 * Params:
 *  mt = type for which the dot expression is used
 *  sc = instantiating scope
 *  e = expression to convert
 *  ident = identifier being used
 *  flag = DotExpFlag bit flags
 *
 * Returns:
 *  resulting expression with e.ident resolved
 */
Expression dotExp(Type mt, Scope* sc, Expression e, Identifier ident, int flag)
{
    Expression visitType(Type mt)
    {
        VarDeclaration v = null;
        static if (LOGDOTEXP)
        {
            printf("Type::dotExp(e = '%s', ident = '%s')\n", e.toChars(), ident.toChars());
        }
        Expression ex = e;
        while (ex.op == TOK.comma)
            ex = (cast(CommaExp)ex).e2;
        if (ex.op == TOK.dotVariable)
        {
            DotVarExp dv = cast(DotVarExp)ex;
            v = dv.var.isVarDeclaration();
        }
        else if (ex.op == TOK.variable)
        {
            VarExp ve = cast(VarExp)ex;
            v = ve.var.isVarDeclaration();
        }
        if (v)
        {
            if (ident == Id.offsetof)
            {
                if (v.isField())
                {
                    auto ad = v.toParent().isAggregateDeclaration();
                    objc.checkOffsetof(e, ad);
                    ad.size(e.loc);
                    if (ad.sizeok != Sizeok.done)
                        return new ErrorExp();
                    return new IntegerExp(e.loc, v.offset, Type.tsize_t);
                }
            }
            else if (ident == Id._init)
            {
                Type tb = mt.toBasetype();
                e = mt.defaultInitLiteral(e.loc);
                if (tb.ty == Tstruct && tb.needsNested())
                {
                    e.isStructLiteralExp().useStaticInit = true;
                }
                goto Lreturn;
            }
        }
        if (ident == Id.stringof)
        {
            /* https://issues.dlang.org/show_bug.cgi?id=3796
             * this should demangle e.type.deco rather than
             * pretty-printing the type.
             */
            const s = e.toChars();
            e = new StringExp(e.loc, cast(char*)s);
        }
        else
            e = mt.getProperty(e.loc, ident, flag & DotExpFlag.gag);

    Lreturn:
        if (e)
            e = e.expressionSemantic(sc);
        return e;
    }

    Expression visitError(TypeError)
    {
        return new ErrorExp();
    }

    Expression visitBasic(TypeBasic mt)
    {
        static if (LOGDOTEXP)
        {
            printf("TypeBasic::dotExp(e = '%s', ident = '%s')\n", e.toChars(), ident.toChars());
        }
        Type t;
        if (ident == Id.re)
        {
            switch (mt.ty)
            {
            case Tcomplex32:
                t = mt.tfloat32;
                goto L1;

            case Tcomplex64:
                t = mt.tfloat64;
                goto L1;

            case Tcomplex80:
                t = mt.tfloat80;
                goto L1;
            L1:
                e = e.castTo(sc, t);
                break;

            case Tfloat32:
            case Tfloat64:
            case Tfloat80:
                break;

            case Timaginary32:
                t = mt.tfloat32;
                goto L2;

            case Timaginary64:
                t = mt.tfloat64;
                goto L2;

            case Timaginary80:
                t = mt.tfloat80;
                goto L2;
            L2:
                e = new RealExp(e.loc, CTFloat.zero, t);
                break;

            default:
                e = mt.Type.getProperty(e.loc, ident, flag);
                break;
            }
        }
        else if (ident == Id.im)
        {
            Type t2;
            switch (mt.ty)
            {
            case Tcomplex32:
                t = mt.timaginary32;
                t2 = mt.tfloat32;
                goto L3;

            case Tcomplex64:
                t = mt.timaginary64;
                t2 = mt.tfloat64;
                goto L3;

            case Tcomplex80:
                t = mt.timaginary80;
                t2 = mt.tfloat80;
                goto L3;
            L3:
                e = e.castTo(sc, t);
                e.type = t2;
                break;

            case Timaginary32:
                t = mt.tfloat32;
                goto L4;

            case Timaginary64:
                t = mt.tfloat64;
                goto L4;

            case Timaginary80:
                t = mt.tfloat80;
                goto L4;
            L4:
                e = e.copy();
                e.type = t;
                break;

            case Tfloat32:
            case Tfloat64:
            case Tfloat80:
                e = new RealExp(e.loc, CTFloat.zero, mt);
                break;

            default:
                e = mt.Type.getProperty(e.loc, ident, flag);
                break;
            }
        }
        else
        {
            return visitType(mt);
        }
        if (!(flag & 1) || e)
            e = e.expressionSemantic(sc);
        return e;
    }

    Expression visitVector(TypeVector mt)
    {
        static if (LOGDOTEXP)
        {
            printf("TypeVector::dotExp(e = '%s', ident = '%s')\n", e.toChars(), ident.toChars());
        }
        if (ident == Id.ptr && e.op == TOK.call)
        {
            /* The trouble with TOK.call is the return ABI for float[4] is different from
             * __vector(float[4]), and a type paint won't do.
             */
            e = new AddrExp(e.loc, e);
            e = e.expressionSemantic(sc);
            return e.castTo(sc, mt.basetype.nextOf().pointerTo());
        }
        if (ident == Id.array)
        {
            //e = e.castTo(sc, basetype);
            // Keep lvalue-ness
            e = new VectorArrayExp(e.loc, e);
            e = e.expressionSemantic(sc);
            return e;
        }
        if (ident == Id._init || ident == Id.offsetof || ident == Id.stringof || ident == Id.__xalignof)
        {
            // init should return a new VectorExp
            // https://issues.dlang.org/show_bug.cgi?id=12776
            // offsetof does not work on a cast expression, so use e directly
            // stringof should not add a cast to the output
            return visitType(mt);
        }
        return mt.basetype.dotExp(sc, e.castTo(sc, mt.basetype), ident, flag);
    }

    Expression visitArray(TypeArray mt)
    {
        static if (LOGDOTEXP)
        {
            printf("TypeArray::dotExp(e = '%s', ident = '%s')\n", e.toChars(), ident.toChars());
        }

        e = visitType(mt);

        if (!(flag & 1) || e)
            e = e.expressionSemantic(sc);
        return e;
    }

    Expression visitSArray(TypeSArray mt)
    {
        static if (LOGDOTEXP)
        {
            printf("TypeSArray::dotExp(e = '%s', ident = '%s')\n", e.toChars(), ident.toChars());
        }
        if (ident == Id.length)
        {
            Loc oldLoc = e.loc;
            e = mt.dim.copy();
            e.loc = oldLoc;
        }
        else if (ident == Id.ptr)
        {
            if (e.op == TOK.type)
            {
                e.error("`%s` is not an expression", e.toChars());
                return new ErrorExp();
            }
            else if (!(flag & DotExpFlag.noDeref) && sc.func && !sc.intypeof && sc.func.setUnsafe() && !(sc.flags & SCOPE.debug_))
            {
                e.error("`%s.ptr` cannot be used in `@safe` code, use `&%s[0]` instead", e.toChars(), e.toChars());
                return new ErrorExp();
            }
            e = e.castTo(sc, e.type.nextOf().pointerTo());
        }
        else
        {
            e = visitArray(mt);
        }
        if (!(flag & 1) || e)
            e = e.expressionSemantic(sc);
        return e;
    }

    Expression visitDArray(TypeDArray mt)
    {
        static if (LOGDOTEXP)
        {
            printf("TypeDArray::dotExp(e = '%s', ident = '%s')\n", e.toChars(), ident.toChars());
        }
        if (e.op == TOK.type && (ident == Id.length || ident == Id.ptr))
        {
            e.error("`%s` is not an expression", e.toChars());
            return new ErrorExp();
        }
        if (ident == Id.length)
        {
            if (e.op == TOK.string_)
            {
                StringExp se = cast(StringExp)e;
                return new IntegerExp(se.loc, se.len, Type.tsize_t);
            }
            if (e.op == TOK.null_)
            {
                return new IntegerExp(e.loc, 0, Type.tsize_t);
            }
            if (checkNonAssignmentArrayOp(e))
            {
                return new ErrorExp();
            }
            e = new ArrayLengthExp(e.loc, e);
            e.type = Type.tsize_t;
            return e;
        }
        else if (ident == Id.ptr)
        {
            if (!(flag & DotExpFlag.noDeref) && sc.func && !sc.intypeof && sc.func.setUnsafe() && !(sc.flags & SCOPE.debug_))
            {
                e.error("`%s.ptr` cannot be used in `@safe` code, use `&%s[0]` instead", e.toChars(), e.toChars());
                return new ErrorExp();
            }
            return e.castTo(sc, mt.next.pointerTo());
        }
        else
        {
            return visitArray(mt);
        }
    }

    Expression visitAArray(TypeAArray mt)
    {
        static if (LOGDOTEXP)
        {
            printf("TypeAArray::dotExp(e = '%s', ident = '%s')\n", e.toChars(), ident.toChars());
        }
        if (ident == Id.length)
        {
            __gshared FuncDeclaration fd_aaLen = null;
            if (fd_aaLen is null)
            {
                auto fparams = new Parameters();
                fparams.push(new Parameter(STC.in_, mt, null, null, null));
                fd_aaLen = FuncDeclaration.genCfunc(fparams, Type.tsize_t, Id.aaLen);
                TypeFunction tf = fd_aaLen.type.toTypeFunction();
                tf.purity = PURE.const_;
                tf.isnothrow = true;
                tf.isnogc = false;
            }
            Expression ev = new VarExp(e.loc, fd_aaLen, false);
            e = new CallExp(e.loc, ev, e);
            e.type = fd_aaLen.type.toTypeFunction().next;
            return e;
        }
        else
        {
            return visitType(mt);
        }
    }

    Expression visitReference(TypeReference mt)
    {
        static if (LOGDOTEXP)
        {
            printf("TypeReference::dotExp(e = '%s', ident = '%s')\n", e.toChars(), ident.toChars());
        }
        // References just forward things along
        return mt.next.dotExp(sc, e, ident, flag);
    }

    Expression visitDelegate(TypeDelegate mt)
    {
        static if (LOGDOTEXP)
        {
            printf("TypeDelegate::dotExp(e = '%s', ident = '%s')\n", e.toChars(), ident.toChars());
        }
        if (ident == Id.ptr)
        {
            e = new DelegatePtrExp(e.loc, e);
            e = e.expressionSemantic(sc);
        }
        else if (ident == Id.funcptr)
        {
            if (!(flag & DotExpFlag.noDeref) && sc.func && !sc.intypeof && sc.func.setUnsafe() && !(sc.flags & SCOPE.debug_))
            {
                e.error("`%s.funcptr` cannot be used in `@safe` code", e.toChars());
                return new ErrorExp();
            }
            e = new DelegateFuncptrExp(e.loc, e);
            e = e.expressionSemantic(sc);
        }
        else
        {
            return visitType(mt);
        }
        return e;
    }

    /***************************************
     * Figures out what to do with an undefined member reference
     * for classes and structs.
     *
     * If flag & 1, don't report "not a property" error and just return NULL.
     */
    Expression noMember(Type mt, Scope* sc, Expression e, Identifier ident, int flag)
    {
        //printf("Type.noMember(e: %s ident: %s flag: %d)\n", e.toChars(), ident.toChars(), flag);

        bool gagError = flag & 1;

        __gshared int nest;      // https://issues.dlang.org/show_bug.cgi?id=17380

        static Expression returnExp(Expression e)
        {
            --nest;
            return e;
        }

        if (++nest > 500)
        {
            .error(e.loc, "cannot resolve identifier `%s`", ident.toChars());
            return returnExp(gagError ? null : new ErrorExp());
        }


        assert(mt.ty == Tstruct || mt.ty == Tclass);
        auto sym = mt.toDsymbol(sc).isAggregateDeclaration();
        assert(sym);
        if (ident != Id.__sizeof &&
            ident != Id.__xalignof &&
            ident != Id._init &&
            ident != Id._mangleof &&
            ident != Id.stringof &&
            ident != Id.offsetof &&
            // https://issues.dlang.org/show_bug.cgi?id=15045
            // Don't forward special built-in member functions.
            ident != Id.ctor &&
            ident != Id.dtor &&
            ident != Id.__xdtor &&
            ident != Id.postblit &&
            ident != Id.__xpostblit)
        {
            /* Look for overloaded opDot() to see if we should forward request
             * to it.
             */
            if (auto fd = search_function(sym, Id.opDot))
            {
                /* Rewrite e.ident as:
                 *  e.opDot().ident
                 */
                e = build_overload(e.loc, sc, e, null, fd);
                // @@@DEPRECATED_2.087@@@.
                e.deprecation("`opDot` is deprecated. Use `alias this`");
                e = new DotIdExp(e.loc, e, ident);
                return returnExp(e.expressionSemantic(sc));
            }

            /* Look for overloaded opDispatch to see if we should forward request
             * to it.
             */
            if (auto fd = search_function(sym, Id.opDispatch))
            {
                /* Rewrite e.ident as:
                 *  e.opDispatch!("ident")
                 */
                TemplateDeclaration td = fd.isTemplateDeclaration();
                if (!td)
                {
                    fd.error("must be a template `opDispatch(string s)`, not a %s", fd.kind());
                    return returnExp(new ErrorExp());
                }
                auto se = new StringExp(e.loc, cast(char*)ident.toChars());
                auto tiargs = new Objects();
                tiargs.push(se);
                auto dti = new DotTemplateInstanceExp(e.loc, e, Id.opDispatch, tiargs);
                dti.ti.tempdecl = td;
                /* opDispatch, which doesn't need IFTI,  may occur instantiate error.
                 * e.g.
                 *  template opDispatch(name) if (isValid!name) { ... }
                 */
                uint errors = gagError ? global.startGagging() : 0;
                e = dti.semanticY(sc, 0);
                if (gagError && global.endGagging(errors))
                    e = null;
                return returnExp(e);
            }

            /* See if we should forward to the alias this.
             */
            auto alias_e = resolveAliasThis(sc, e, gagError);
            if (alias_e && alias_e != e)
            {
                /* Rewrite e.ident as:
                 *  e.aliasthis.ident
                 */
                auto die = new DotIdExp(e.loc, alias_e, ident);

                auto errors = gagError ? 0 : global.startGagging();
                auto exp = die.semanticY(sc, gagError);
                if (!gagError)
                {
                    global.endGagging(errors);
                    if (exp && exp.op == TOK.error)
                        exp = null;
                }

                if (exp && gagError)
                    // now that we know that the alias this leads somewhere useful,
                    // go back and print deprecations/warnings that we skipped earlier due to the gag
                    resolveAliasThis(sc, e, false);

                return returnExp(exp);
            }
        }
        return returnExp(visitType(mt));
    }

    Expression visitStruct(TypeStruct mt)
    {
        Dsymbol s;
        static if (LOGDOTEXP)
        {
            printf("TypeStruct::dotExp(e = '%s', ident = '%s')\n", e.toChars(), ident.toChars());
        }
        assert(e.op != TOK.dot);

        // https://issues.dlang.org/show_bug.cgi?id=14010
        if (ident == Id._mangleof)
        {
            return mt.getProperty(e.loc, ident, flag & 1);
        }

        /* If e.tupleof
         */
        if (ident == Id._tupleof)
        {
            /* Create a TupleExp out of the fields of the struct e:
             * (e.field0, e.field1, e.field2, ...)
             */
            e = e.expressionSemantic(sc); // do this before turning on noaccesscheck

            if (!mt.sym.determineFields())
            {
                error(e.loc, "unable to determine fields of `%s` because of forward references", mt.toChars());
            }

            Expression e0;
            Expression ev = e.op == TOK.type ? null : e;
            if (ev)
                ev = extractSideEffect(sc, "__tup", e0, ev);

            auto exps = new Expressions();
            exps.reserve(mt.sym.fields.dim);
            for (size_t i = 0; i < mt.sym.fields.dim; i++)
            {
                VarDeclaration v = mt.sym.fields[i];
                Expression ex;
                if (ev)
                    ex = new DotVarExp(e.loc, ev, v);
                else
                {
                    ex = new VarExp(e.loc, v);
                    ex.type = ex.type.addMod(e.type.mod);
                }
                exps.push(ex);
            }

            e = new TupleExp(e.loc, e0, exps);
            Scope* sc2 = sc.push();
            sc2.flags |= global.params.vsafe ? SCOPE.onlysafeaccess : SCOPE.noaccesscheck;
            e = e.expressionSemantic(sc2);
            sc2.pop();
            return e;
        }

        immutable flags = sc.flags & SCOPE.ignoresymbolvisibility ? IgnoreSymbolVisibility : 0;
        s = mt.sym.search(e.loc, ident, flags | IgnorePrivateImports);
    L1:
        if (!s)
        {
            return noMember(mt, sc, e, ident, flag);
        }
        if (!(sc.flags & SCOPE.ignoresymbolvisibility) && !symbolIsVisible(sc, s))
        {
            return noMember(mt, sc, e, ident, flag);
        }
        if (!s.isFuncDeclaration()) // because of overloading
        {
            s.checkDeprecated(e.loc, sc);
            if (auto d = s.isDeclaration())
                d.checkDisabled(e.loc, sc);
        }
        s = s.toAlias();

        if (auto em = s.isEnumMember())
        {
            return em.getVarExp(e.loc, sc);
        }
        if (auto v = s.isVarDeclaration())
        {
            if (!v.type ||
                !v.type.deco && v.inuse)
            {
                if (v.inuse) // https://issues.dlang.org/show_bug.cgi?id=9494
                    e.error("circular reference to %s `%s`", v.kind(), v.toPrettyChars());
                else
                    e.error("forward reference to %s `%s`", v.kind(), v.toPrettyChars());
                return new ErrorExp();
            }
            if (v.type.ty == Terror)
            {
                return new ErrorExp();
            }

            if ((v.storage_class & STC.manifest) && v._init)
            {
                if (v.inuse)
                {
                    e.error("circular initialization of %s `%s`", v.kind(), v.toPrettyChars());
                    return new ErrorExp();
                }
                checkAccess(e.loc, sc, null, v);
                Expression ve = new VarExp(e.loc, v);
                if (!isTrivialExp(e))
                {
                    ve = new CommaExp(e.loc, e, ve);
                }
                return ve.expressionSemantic(sc);
            }
        }

        if (auto t = s.getType())
        {
            return (new TypeExp(e.loc, t)).expressionSemantic(sc);
        }

        TemplateMixin tm = s.isTemplateMixin();
        if (tm)
        {
            Expression de = new DotExp(e.loc, e, new ScopeExp(e.loc, tm));
            de.type = e.type;
            return de;
        }

        TemplateDeclaration td = s.isTemplateDeclaration();
        if (td)
        {
            if (e.op == TOK.type)
                e = new TemplateExp(e.loc, td);
            else
                e = new DotTemplateExp(e.loc, e, td);
            return e.expressionSemantic(sc);
        }

        TemplateInstance ti = s.isTemplateInstance();
        if (ti)
        {
            if (!ti.semanticRun)
            {
                ti.dsymbolSemantic(sc);
                if (!ti.inst || ti.errors) // if template failed to expand
                {
                    return new ErrorExp();
                }
            }
            s = ti.inst.toAlias();
            if (!s.isTemplateInstance())
                goto L1;
            if (e.op == TOK.type)
                e = new ScopeExp(e.loc, ti);
            else
                e = new DotExp(e.loc, e, new ScopeExp(e.loc, ti));
            return e.expressionSemantic(sc);
        }

        if (s.isImport() || s.isModule() || s.isPackage())
        {
            return symbolToExp(s, e.loc, sc, false);
        }

        OverloadSet o = s.isOverloadSet();
        if (o)
        {
            auto oe = new OverExp(e.loc, o);
            if (e.op == TOK.type)
            {
                return oe;
            }
            return new DotExp(e.loc, e, oe);
        }

        Declaration d = s.isDeclaration();
        if (!d)
        {
            e.error("`%s.%s` is not a declaration", e.toChars(), ident.toChars());
            return new ErrorExp();
        }

        if (e.op == TOK.type)
        {
            /* It's:
             *    Struct.d
             */
            if (TupleDeclaration tup = d.isTupleDeclaration())
            {
                e = new TupleExp(e.loc, tup);
                return e.expressionSemantic(sc);
            }
            if (d.needThis() && sc.intypeof != 1)
            {
                /* Rewrite as:
                 *  this.d
                 */
                if (hasThis(sc))
                {
                    e = new DotVarExp(e.loc, new ThisExp(e.loc), d);
                    return e.expressionSemantic(sc);
                }
            }
            if (d.semanticRun == PASS.init)
                d.dsymbolSemantic(null);
            checkAccess(e.loc, sc, e, d);
            auto ve = new VarExp(e.loc, d);
            if (d.isVarDeclaration() && d.needThis())
                ve.type = d.type.addMod(e.type.mod);
            return ve;
        }

        bool unreal = e.op == TOK.variable && (cast(VarExp)e).var.isField();
        if (d.isDataseg() || unreal && d.isField())
        {
            // (e, d)
            checkAccess(e.loc, sc, e, d);
            Expression ve = new VarExp(e.loc, d);
            e = unreal ? ve : new CommaExp(e.loc, e, ve);
            return e.expressionSemantic(sc);
        }

        e = new DotVarExp(e.loc, e, d);
        return e.expressionSemantic(sc);
    }

    Expression visitEnum(TypeEnum mt)
    {
        static if (LOGDOTEXP)
        {
            printf("TypeEnum::dotExp(e = '%s', ident = '%s') '%s'\n", e.toChars(), ident.toChars(), mt.toChars());
        }
        // https://issues.dlang.org/show_bug.cgi?id=14010
        if (ident == Id._mangleof)
        {
            return mt.getProperty(e.loc, ident, flag & 1);
        }

        if (mt.sym.semanticRun < PASS.semanticdone)
            mt.sym.dsymbolSemantic(null);
        if (!mt.sym.members)
        {
            if (mt.sym.isSpecial())
            {
                /* Special enums forward to the base type
                 */
                e = mt.sym.memtype.dotExp(sc, e, ident, flag);
            }
            else if (!(flag & 1))
            {
                mt.sym.error("is forward referenced when looking for `%s`", ident.toChars());
                e = new ErrorExp();
            }
            else
                e = null;
            return e;
        }

        Dsymbol s = mt.sym.search(e.loc, ident);
        if (!s)
        {
            if (ident == Id.max || ident == Id.min || ident == Id._init)
            {
                return mt.getProperty(e.loc, ident, flag & 1);
            }

            Expression res = mt.sym.getMemtype(Loc.initial).dotExp(sc, e, ident, 1);
            if (!(flag & 1) && !res)
            {
                if (auto ns = mt.sym.search_correct(ident))
                    e.error("no property `%s` for type `%s`. Did you mean `%s.%s` ?", ident.toChars(), mt.toChars(), mt.toChars(),
                        ns.toChars());
                else
                    e.error("no property `%s` for type `%s`", ident.toChars(),
                        mt.toChars());

                return new ErrorExp();
            }
            return res;
        }
        EnumMember m = s.isEnumMember();
        return m.getVarExp(e.loc, sc);
    }

    Expression visitClass(TypeClass mt)
    {
        Dsymbol s;
        static if (LOGDOTEXP)
        {
            printf("TypeClass::dotExp(e = '%s', ident = '%s')\n", e.toChars(), ident.toChars());
        }
        assert(e.op != TOK.dot);

        // https://issues.dlang.org/show_bug.cgi?id=12543
        if (ident == Id.__sizeof || ident == Id.__xalignof || ident == Id._mangleof)
        {
            return mt.Type.getProperty(e.loc, ident, 0);
        }

        /* If e.tupleof
         */
        if (ident == Id._tupleof)
        {
            objc.checkTupleof(e, mt);

            /* Create a TupleExp
             */
            e = e.expressionSemantic(sc); // do this before turning on noaccesscheck

            mt.sym.size(e.loc); // do semantic of type

            Expression e0;
            Expression ev = e.op == TOK.type ? null : e;
            if (ev)
                ev = extractSideEffect(sc, "__tup", e0, ev);

            auto exps = new Expressions();
            exps.reserve(mt.sym.fields.dim);
            for (size_t i = 0; i < mt.sym.fields.dim; i++)
            {
                VarDeclaration v = mt.sym.fields[i];
                // Don't include hidden 'this' pointer
                if (v.isThisDeclaration())
                    continue;
                Expression ex;
                if (ev)
                    ex = new DotVarExp(e.loc, ev, v);
                else
                {
                    ex = new VarExp(e.loc, v);
                    ex.type = ex.type.addMod(e.type.mod);
                }
                exps.push(ex);
            }

            e = new TupleExp(e.loc, e0, exps);
            Scope* sc2 = sc.push();
            sc2.flags |= global.params.vsafe ? SCOPE.onlysafeaccess : SCOPE.noaccesscheck;
            e = e.expressionSemantic(sc2);
            sc2.pop();
            return e;
        }

        int flags = sc.flags & SCOPE.ignoresymbolvisibility ? IgnoreSymbolVisibility : 0;
        s = mt.sym.search(e.loc, ident, flags | IgnorePrivateImports);

    L1:
        if (!s)
        {
            // See if it's 'this' class or a base class
            if (mt.sym.ident == ident)
            {
                if (e.op == TOK.type)
                {
                    return mt.Type.getProperty(e.loc, ident, 0);
                }
                e = new DotTypeExp(e.loc, e, mt.sym);
                e = e.expressionSemantic(sc);
                return e;
            }
            if (auto cbase = mt.sym.searchBase(ident))
            {
                if (e.op == TOK.type)
                {
                    return mt.Type.getProperty(e.loc, ident, 0);
                }
                if (auto ifbase = cbase.isInterfaceDeclaration())
                    e = new CastExp(e.loc, e, ifbase.type);
                else
                    e = new DotTypeExp(e.loc, e, cbase);
                e = e.expressionSemantic(sc);
                return e;
            }

            if (ident == Id.classinfo)
            {
                if (!Type.typeinfoclass)
                {
                    error(e.loc, "`object.TypeInfo_Class` could not be found, but is implicitly used");
                    return new ErrorExp();
                }

                Type t = Type.typeinfoclass.type;
                if (e.op == TOK.type || e.op == TOK.dotType)
                {
                    /* For type.classinfo, we know the classinfo
                     * at compile time.
                     */
                    if (!mt.sym.vclassinfo)
                        mt.sym.vclassinfo = new TypeInfoClassDeclaration(mt.sym.type);
                    e = new VarExp(e.loc, mt.sym.vclassinfo);
                    e = e.addressOf();
                    e.type = t; // do this so we don't get redundant dereference
                }
                else
                {
                    /* For class objects, the classinfo reference is the first
                     * entry in the vtbl[]
                     */
                    e = new PtrExp(e.loc, e);
                    e.type = t.pointerTo();
                    if (mt.sym.isInterfaceDeclaration())
                    {
                        if (mt.sym.isCPPinterface())
                        {
                            /* C++ interface vtbl[]s are different in that the
                             * first entry is always pointer to the first virtual
                             * function, not classinfo.
                             * We can't get a .classinfo for it.
                             */
                            error(e.loc, "no `.classinfo` for C++ interface objects");
                        }
                        /* For an interface, the first entry in the vtbl[]
                         * is actually a pointer to an instance of struct Interface.
                         * The first member of Interface is the .classinfo,
                         * so add an extra pointer indirection.
                         */
                        e.type = e.type.pointerTo();
                        e = new PtrExp(e.loc, e);
                        e.type = t.pointerTo();
                    }
                    e = new PtrExp(e.loc, e, t);
                }
                return e;
            }

            if (ident == Id.__vptr)
            {
                /* The pointer to the vtbl[]
                 * *cast(immutable(void*)**)e
                 */
                e = e.castTo(sc, mt.tvoidptr.immutableOf().pointerTo().pointerTo());
                e = new PtrExp(e.loc, e);
                e = e.expressionSemantic(sc);
                return e;
            }

            if (ident == Id.__monitor && mt.sym.hasMonitor())
            {
                /* The handle to the monitor (call it a void*)
                 * *(cast(void**)e + 1)
                 */
                e = e.castTo(sc, mt.tvoidptr.pointerTo());
                e = new AddExp(e.loc, e, IntegerExp.literal!1);
                e = new PtrExp(e.loc, e);
                e = e.expressionSemantic(sc);
                return e;
            }

            if (ident == Id.outer && mt.sym.vthis)
            {
                if (mt.sym.vthis.semanticRun == PASS.init)
                    mt.sym.vthis.dsymbolSemantic(null);

                if (auto cdp = mt.sym.toParentLocal().isClassDeclaration())
                {
                    auto dve = new DotVarExp(e.loc, e, mt.sym.vthis);
                    dve.type = cdp.type.addMod(e.type.mod);
                    return dve;
                }

                /* https://issues.dlang.org/show_bug.cgi?id=15839
                 * Find closest parent class through nested functions.
                 */
                for (auto p = mt.sym.toParentLocal(); p; p = p.toParentLocal())
                {
                    auto fd = p.isFuncDeclaration();
                    if (!fd)
                        break;
                    auto ad = fd.isThis();
                    if (!ad && fd.isNested())
                        continue;
                    if (!ad)
                        break;
                    if (auto cdp = ad.isClassDeclaration())
                    {
                        auto ve = new ThisExp(e.loc);

                        ve.var = fd.vthis;
                        const nestedError = fd.vthis.checkNestedReference(sc, e.loc);
                        assert(!nestedError);

                        ve.type = cdp.type.addMod(fd.vthis.type.mod).addMod(e.type.mod);
                        return ve;
                    }
                    break;
                }

                // Continue to show enclosing function's frame (stack or closure).
                auto dve = new DotVarExp(e.loc, e, mt.sym.vthis);
                dve.type = mt.sym.vthis.type.addMod(e.type.mod);
                return dve;
            }

            return noMember(mt, sc, e, ident, flag & 1);
        }
        if (!(sc.flags & SCOPE.ignoresymbolvisibility) && !symbolIsVisible(sc, s))
        {
            return noMember(mt, sc, e, ident, flag);
        }
        if (!s.isFuncDeclaration()) // because of overloading
        {
            s.checkDeprecated(e.loc, sc);
            if (auto d = s.isDeclaration())
                d.checkDisabled(e.loc, sc);
        }
        s = s.toAlias();

        if (auto em = s.isEnumMember())
        {
            return em.getVarExp(e.loc, sc);
        }
        if (auto v = s.isVarDeclaration())
        {
            if (!v.type ||
                !v.type.deco && v.inuse)
            {
                if (v.inuse) // https://issues.dlang.org/show_bug.cgi?id=9494
                    e.error("circular reference to %s `%s`", v.kind(), v.toPrettyChars());
                else
                    e.error("forward reference to %s `%s`", v.kind(), v.toPrettyChars());
                return new ErrorExp();
            }
            if (v.type.ty == Terror)
            {
                return new ErrorExp();
            }

            if ((v.storage_class & STC.manifest) && v._init)
            {
                if (v.inuse)
                {
                    e.error("circular initialization of %s `%s`", v.kind(), v.toPrettyChars());
                    return new ErrorExp();
                }
                checkAccess(e.loc, sc, null, v);
                Expression ve = new VarExp(e.loc, v);
                ve = ve.expressionSemantic(sc);
                return ve;
            }
        }

        if (auto t = s.getType())
        {
            return (new TypeExp(e.loc, t)).expressionSemantic(sc);
        }

        TemplateMixin tm = s.isTemplateMixin();
        if (tm)
        {
            Expression de = new DotExp(e.loc, e, new ScopeExp(e.loc, tm));
            de.type = e.type;
            return de;
        }

        TemplateDeclaration td = s.isTemplateDeclaration();
        if (td)
        {
            if (e.op == TOK.type)
                e = new TemplateExp(e.loc, td);
            else
                e = new DotTemplateExp(e.loc, e, td);
            e = e.expressionSemantic(sc);
            return e;
        }

        TemplateInstance ti = s.isTemplateInstance();
        if (ti)
        {
            if (!ti.semanticRun)
            {
                ti.dsymbolSemantic(sc);
                if (!ti.inst || ti.errors) // if template failed to expand
                {
                    return new ErrorExp();
                }
            }
            s = ti.inst.toAlias();
            if (!s.isTemplateInstance())
                goto L1;
            if (e.op == TOK.type)
                e = new ScopeExp(e.loc, ti);
            else
                e = new DotExp(e.loc, e, new ScopeExp(e.loc, ti));
            return e.expressionSemantic(sc);
        }

        if (s.isImport() || s.isModule() || s.isPackage())
        {
            e = symbolToExp(s, e.loc, sc, false);
            return e;
        }

        OverloadSet o = s.isOverloadSet();
        if (o)
        {
            auto oe = new OverExp(e.loc, o);
            if (e.op == TOK.type)
            {
                return oe;
            }
            return new DotExp(e.loc, e, oe);
        }

        Declaration d = s.isDeclaration();
        if (!d)
        {
            e.error("`%s.%s` is not a declaration", e.toChars(), ident.toChars());
            return new ErrorExp();
        }

        if (e.op == TOK.type)
        {
            /* It's:
             *    Class.d
             */
            if (TupleDeclaration tup = d.isTupleDeclaration())
            {
                e = new TupleExp(e.loc, tup);
                e = e.expressionSemantic(sc);
                return e;
            }

            if (mt.sym.classKind == ClassKind.objc
                && d.isFuncDeclaration()
                && d.isFuncDeclaration().isStatic
                && d.isFuncDeclaration().selector)
            {
                auto classRef = new ObjcClassReferenceExp(e.loc, mt.sym);
                return new DotVarExp(e.loc, classRef, d).expressionSemantic(sc);
            }
            else if (d.needThis() && sc.intypeof != 1)
            {
                /* Rewrite as:
                 *  this.d
                 */
                AggregateDeclaration ad = d.isMemberLocal();
                if (auto f = hasThis(sc))
                {
                    // This is almost same as getRightThis() in expressionsem.d
                    Expression e1;
                    Type t;
                    /* returns: true to continue, false to return */
                    if (f.isThis2)
                    {
                        if (f.followInstantiationContext(ad))
                        {
                            e1 = new VarExp(e.loc, f.vthis);
                            e1 = new PtrExp(e1.loc, e1);
                            e1 = new IndexExp(e1.loc, e1, IntegerExp.literal!1);
                            auto pd = f.toParent2().isDeclaration();
                            assert(pd);
                            t = pd.type.toBasetype();
                            e1 = getThisSkipNestedFuncs(e1.loc, sc, f.toParent2(), ad, e1, t, d, true);
                            if (!e1)
                            {
                                e = new VarExp(e.loc, d);
                                return e;
                            }
                            goto L2;
                        }
                    }
                    e1 = new ThisExp(e.loc);
                    e1 = e1.expressionSemantic(sc);
                L2:
                    t = e1.type.toBasetype();
                    ClassDeclaration cd = e.type.isClassHandle();
                    ClassDeclaration tcd = t.isClassHandle();
                    if (cd && tcd && (tcd == cd || cd.isBaseOf(tcd, null)))
                    {
                        e = new DotTypeExp(e1.loc, e1, cd);
                        e = new DotVarExp(e.loc, e, d);
                        e = e.expressionSemantic(sc);
                        return e;
                    }
                    if (tcd && tcd.isNested())
                    {
                        /* e1 is the 'this' pointer for an inner class: tcd.
                         * Rewrite it as the 'this' pointer for the outer class.
                         */
                        auto vthis = tcd.followInstantiationContext(ad) ? tcd.vthis2 : tcd.vthis;
                        e1 = new DotVarExp(e.loc, e1, vthis);
                        e1.type = vthis.type;
                        e1.type = e1.type.addMod(t.mod);
                        // Do not call ensureStaticLinkTo()
                        //e1 = e1.expressionSemantic(sc);

                        // Skip up over nested functions, and get the enclosing
                        // class type.
                        e1 = getThisSkipNestedFuncs(e1.loc, sc, tcd.toParentP(ad), ad, e1, t, d, true);
                        if (!e1)
                        {
                            e = new VarExp(e.loc, d);
                            return e;
                        }
                        goto L2;
                    }
                }
            }
            //printf("e = %s, d = %s\n", e.toChars(), d.toChars());
            if (d.semanticRun == PASS.init)
                d.dsymbolSemantic(null);

            // If static function, get the most visible overload.
            // Later on the call is checked for correctness.
            // https://issues.dlang.org/show_bug.cgi?id=12511
            if (auto fd = d.isFuncDeclaration())
            {
                import dmd.access : mostVisibleOverload;
                d = cast(Declaration)mostVisibleOverload(fd, sc._module);
            }

            checkAccess(e.loc, sc, e, d);
            auto ve = new VarExp(e.loc, d);
            if (d.isVarDeclaration() && d.needThis())
                ve.type = d.type.addMod(e.type.mod);
            return ve;
        }

        bool unreal = e.op == TOK.variable && (cast(VarExp)e).var.isField();
        if (d.isDataseg() || unreal && d.isField())
        {
            // (e, d)
            checkAccess(e.loc, sc, e, d);
            Expression ve = new VarExp(e.loc, d);
            e = unreal ? ve : new CommaExp(e.loc, e, ve);
            e = e.expressionSemantic(sc);
            return e;
        }

        e = new DotVarExp(e.loc, e, d);
        e = e.expressionSemantic(sc);
        return e;
    }

    switch (mt.ty)
    {
        case Tvector:    return visitVector   (cast(TypeVector)mt);
        case Tsarray:    return visitSArray   (cast(TypeSArray)mt);
        case Tstruct:    return visitStruct   (cast(TypeStruct)mt);
        case Tenum:      return visitEnum     (cast(TypeEnum)mt);
        case Terror:     return visitError    (cast(TypeError)mt);
        case Tarray:     return visitDArray   (cast(TypeDArray)mt);
        case Taarray:    return visitAArray   (cast(TypeAArray)mt);
        case Treference: return visitReference(cast(TypeReference)mt);
        case Tdelegate:  return visitDelegate (cast(TypeDelegate)mt);
        case Tclass:     return visitClass    (cast(TypeClass)mt);

        default:         return mt.isTypeBasic()
                                ? visitBasic(cast(TypeBasic)mt)
                                : visitType(mt);
    }
}


/************************
 * Get the the default initialization expression for a type.
 * Params:
 *  mt = the type for which the init expression is returned
 *  loc = the location where the expression needs to be evaluated
 *
 * Returns:
 *  The initialization expression for the type.
 */
Expression defaultInit(Type mt, const ref Loc loc)
{
    Expression visitBasic(TypeBasic mt)
    {
        static if (LOGDEFAULTINIT)
        {
            printf("TypeBasic::defaultInit() '%s'\n", mt.toChars());
        }
        dinteger_t value = 0;

        switch (mt.ty)
        {
        case Tchar:
            value = 0xFF;
            break;

        case Twchar:
        case Tdchar:
            value = 0xFFFF;
            break;

        case Timaginary32:
        case Timaginary64:
        case Timaginary80:
        case Tfloat32:
        case Tfloat64:
        case Tfloat80:
            return new RealExp(loc, target.RealProperties.nan, mt);

        case Tcomplex32:
        case Tcomplex64:
        case Tcomplex80:
            {
                // Can't use fvalue + I*fvalue (the im part becomes a quiet NaN).
                const cvalue = complex_t(target.RealProperties.nan, target.RealProperties.nan);
                return new ComplexExp(loc, cvalue, mt);
            }

        case Tvoid:
            error(loc, "`void` does not have a default initializer");
            return new ErrorExp();

        default:
            break;
        }
        return new IntegerExp(loc, value, mt);
    }

    Expression visitVector(TypeVector mt)
    {
        //printf("TypeVector::defaultInit()\n");
        assert(mt.basetype.ty == Tsarray);
        Expression e = mt.basetype.defaultInit(loc);
        auto ve = new VectorExp(loc, e, mt);
        ve.type = mt;
        ve.dim = cast(int)(mt.basetype.size(loc) / mt.elementType().size(loc));
        return ve;
    }

    Expression visitSArray(TypeSArray mt)
    {
        static if (LOGDEFAULTINIT)
        {
            printf("TypeSArray::defaultInit() '%s'\n", mt.toChars());
        }
        if (mt.next.ty == Tvoid)
            return mt.tuns8.defaultInit(loc);
        else
            return mt.next.defaultInit(loc);
    }

    Expression visitFunction(TypeFunction mt)
    {
        error(loc, "`function` does not have a default initializer");
        return new ErrorExp();
    }

    Expression visitStruct(TypeStruct mt)
    {
        static if (LOGDEFAULTINIT)
        {
            printf("TypeStruct::defaultInit() '%s'\n", mt.toChars());
        }
        Declaration d = new SymbolDeclaration(mt.sym.loc, mt.sym);
        assert(d);
        d.type = mt;
        d.storage_class |= STC.rvalue; // https://issues.dlang.org/show_bug.cgi?id=14398
        return new VarExp(mt.sym.loc, d);
    }

    Expression visitEnum(TypeEnum mt)
    {
        static if (LOGDEFAULTINIT)
        {
            printf("TypeEnum::defaultInit() '%s'\n", mt.toChars());
        }
        // Initialize to first member of enum
        Expression e = mt.sym.getDefaultValue(loc);
        e = e.copy();
        e.loc = loc;
        e.type = mt; // to deal with const, immutable, etc., variants
        return e;
    }

    Expression visitTuple(TypeTuple mt)
    {
        static if (LOGDEFAULTINIT)
        {
            printf("TypeTuple::defaultInit() '%s'\n", mt.toChars());
        }
        auto exps = new Expressions(mt.arguments.dim);
        for (size_t i = 0; i < mt.arguments.dim; i++)
        {
            Parameter p = (*mt.arguments)[i];
            assert(p.type);
            Expression e = p.type.defaultInitLiteral(loc);
            if (e.op == TOK.error)
            {
                return e;
            }
            (*exps)[i] = e;
        }
        return new TupleExp(loc, exps);
    }

    switch (mt.ty)
    {
        case Tvector:   return visitVector  (cast(TypeVector)mt);
        case Tsarray:   return visitSArray  (cast(TypeSArray)mt);
        case Tfunction: return visitFunction(cast(TypeFunction)mt);
        case Tstruct:   return visitStruct  (cast(TypeStruct)mt);
        case Tenum:     return visitEnum    (cast(TypeEnum)mt);
        case Ttuple:    return visitTuple   (cast(TypeTuple)mt);

        case Tnull:     return new NullExp(Loc.initial, Type.tnull);

        case Terror:    return new ErrorExp();

        case Tarray:
        case Taarray:
        case Tpointer:
        case Treference:
        case Tdelegate:
        case Tclass:    return new NullExp(loc, mt);

        default:        return mt.isTypeBasic() ?
                                visitBasic(cast(TypeBasic)mt) :
                                null;
    }
}
