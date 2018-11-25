/**
 * Compiler implementation of the
 * $(LINK2 http://www.dlang.org, D programming language).
 *
 * Copyright:   Copyright (C) 1999-2018 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 mailto:sahmi.soulaimane@gmail.com, Soulaïmane Sahmi)
 * License:     $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/backend/argtypesv64.d, backend/argtypesv64.d)
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/backend/argtypesv64.d
 */

module dmd.backend.argtypesv64;

import dmd.backend.type;
import dmd.backend.ty;
import dmd.backend.cc;
import dmd.backend.dlist;

extern(C++):


/***************************************
 * Finds one or two types that could replace an aggregate for register
 * passing where each of the types represent a chunk of the aggregate.
 *
 * The types returned are valid for parameter passing and value returns
 * for targets which follow the System V x86_64 calling conventions.
 * (For the ABI spec see https://github.com/hjl-tools/x86-psABI)
 *
 * Params:
 *  t = aggregate type
 *  arg1type = output parameter for the first type
 *  arg1type = output parameter for the second type
 */
void argtypesv64(type *t, type **arg1type, type **arg2type)
{
    assert(t);
    if (!tyaggregate(t.Tty))
        return;

    Group c = classify(t);
    size_t size = type_size(t);
    size_t words = (size + WORD_SIZE - 1) / WORD_SIZE;

    type **argtype = arg1type;
    size_t argsz = size < WORD_SIZE ? size : WORD_SIZE;
    foreach (v; 0 .. 2)
    {
        switch (c[v]) with (Class)
        {
            case NoClass:
            case Memory:
                return;

            case X87:
                *argtype = tstypes[TYldouble];
                break;

            case X87Up:
                assert(v && c[v - 1] == X87);
                break;

            case ComplexX87:
                assert(0);

            case Integer:
                *argtype = argsz == 1 ? tstypes[TYchar]
                        : argsz == 2 ? tstypes[TYshort]
                        : argsz <= 4 ? tstypes[TYlong]
                        : tstypes[TYllong];
                break;

            case SSE:
                if (c[v + 1] == SSEUp)  // SIMD type
                    *argtype = size == 16 ? type_fake(TYdouble2)
                            : size == 32 ? type_fake(TYdouble4)
                            : type_fake(TYdouble8);
                else
                    *argtype = argsz <= 4 ? tstypes[TYfloat]
                            : tstypes[TYdouble];
                break;

            case SSEUp:
                assert(v && c[v - 1] & (SSE | SSEUp));
                break;

            default:
                assert(0);
        }
        argtype = arg2type;
        argsz = size - WORD_SIZE;
    }
}


private:
extern(D):

enum MAX_SIZE = 64;
enum WORD_SIZE = 8;
enum MAX_WORDS = MAX_SIZE / WORD_SIZE;

// type classification
enum Class : ubyte
{
    NoClass    = 0,
    Integer    = 1 << 0,
    SSE        = 1 << 1,
    SSEUp      = 1 << 2,
    X87        = 1 << 3,
    X87Up      = 1 << 4,
    ComplexX87 = 1 << 5,
    Memory     = 1 << 6,
}

// assign a class to each word (8 byte)
Group classify(type *t)
{
    return classifyImpl(t, 0, Group.init);
}

Group classifyImpl(type *t, size_t offset, Group g)
{
    size_t i = offset / WORD_SIZE;  // which word are we at
    Group ng;

    tym_t ty = t.Tty;

    with (Class)
    {
        if (tysimd(ty))
        {
            size_t sz = tysize(ty);
            ng[i] = SSE;
            ng[i + 1 .. i + sz/WORD_SIZE] = SSEUp;
        }

        else if (tybasic(ty) == TYcdouble)
            ng[i .. i + 2] = Group(SSE, SSE);

        else if (tyrelax(ty) == TYcent)
            ng[i .. i + 2] = Group(Integer, Integer);

        else if (tybasic(ty) == TYcldouble)
            ng[i] = ComplexX87;

        else if (tybasic(ty) == TYldouble)
            ng[i .. i + 2] = Group(X87, X87Up);

        else if (tyfloating(ty))
            ng[i] = SSE;

        else if (tyscalar(ty))
            ng[i] = Integer;

        else if (tyaggregate(ty))
        {
            Group ng2, mm;
            mm[] = Memory;

            size_t size = type_size(t);
            size_t w = (size + WORD_SIZE - 1) / WORD_SIZE;

            if (size == 0)
                ng2[] = NoClass;

            else if (size > 64)
                ng2[] = Memory;

            else if (tybasic(ty) == TYarray)
            {
                foreach (v; 0 .. t.Tdim)
                    ng2 = classifyImpl(t.Tnext, v * size, ng2);
            }

            else if (tybasic(ty) == TYstruct)
            {
                if (t.Ttag.Sstruct.Sflags & STRnotpod)
                {
                    ng2[0 .. w] = Memory;
                }
                else for (symlist_t sl = t.Ttag.Sstruct.Sfldlst; sl; sl = list_next(sl))
                {
                    Symbol *sf = list_symbol(sl);
                    size_t foffset = sf.Smemoff;

                    size_t falignsize = type_alignsize(sf.Stype);
                    if (foffset & (falignsize - 1))
                    {
                        ng2[0 .. w] = Memory;
                        break;
                    }

                    ng2 = classifyImpl(sf.Stype, foffset, ng2);
                }

            }

            else
                assert(0);

            ng2 = postmerge(ng2, size);
            ng[i .. i + w] = ng2[0 .. w];
        }

        else
            assert(0);
    }

    return merge(g, ng);
}

Class merge(Class a, Class b)
{
    with (Class)
    {
        if (a == b)
            return a;

        if (a == NoClass)
            return b;

        if (b == NoClass)
            return a;

        if ((a | b) & Memory)
            return Memory;

        if ((a | b) & Integer)
            return Integer;

        if ((a | b) & (X87 | X87Up | ComplexX87))
            return Memory;

        return SSE;
    }
}

Group merge(Group a, Group b)
{
    if (a == b)
        return a;

    Group cls;
    foreach (i; 0 .. MAX_WORDS)
        cls[i] = merge(a[i], b[i]);

    return cls;
}

// post merger for aggregates only
Group postmerge(Group a, size_t size)
{
    size_t w = (size + WORD_SIZE - 1) / WORD_SIZE;

    if (size > 2 * WORD_SIZE)
    {
        if (a[0] != Class.SSE)
            return Group(Class.Memory);

        foreach (i; 1 .. w)
        {
            if (a[i] != Class.SSEUp)
                return Group(Class.Memory);
        }

        return a;
    }

    foreach (i; 0 .. w)
    {
        switch (a[i]) with (Class)
        {
            case Memory:
                return Group(Memory);

            case X87Up:
                if (i == 0 || a[i - 1] != X87)
                    return Group(Memory);
                break;

            case SSEUp:
                if (i == 0 || 0 == (a[i - 1] & (SSE | SSEUp)))
                    a[i] = SSE;
                break;

            default:
                break;
        }
    }

    return a;
}

// An array of 8 classifications, one per each word (8 byte)
// API similar to alias Group = Class[8]
struct Group
{
    // implemented as a bitfield of 8 bytes with a static array interface
    // both for the performance benefit and for the (hopefully) temporary
    // limitations of array operation without druntime (in betterC mode)

    ulong mask = 0;

    this(Class[] a...)
    {
        foreach (i, c; a)
            this[i] = c;
    }

    // array interface

    alias length = MAX_WORDS;
    alias opDollar = length;

    // a[i]
    Class opIndex(size_t i)
    {
        return cast(Class) ((mask >> (i * 8)) & 0xFF);
    }

    // a[] = c
    Class opIndexAssign(Class c)
    {
        return opIndexAssign(c, [0, length]);
    }

    // a[i] = c
    Class opIndexAssign(Class c, size_t i)
    {
        mask = (mask & ~(0xFFUL << (i * 8))) | cast(ulong) c << (i * 8);
        return c;
    }

    // a[i..j] = c
    Class opIndexAssign(Class c, size_t[2] i)
    {
        return opSliceAssign(c, i[0], i[1]);
    }

    // a[i..j] = c
    Class opSliceAssign(Class c, size_t i, size_t j)
    {
        foreach (v; i .. j)
            opIndexAssign(c, v);
        return c;
    }

    // a[i..j] = g
    Group opSliceAssign(Group g, size_t i, size_t j)
    {
        foreach (v; i .. j)
            opIndexAssign(g[v - i], v);
        return this;
    }

    // a[i..j]
    Group opSlice(size_t i, size_t j)
    {
        ulong keep = (~0UL >> (8 - j) * 8) & (~0UL << i * 8);
        Group r;
        r.mask = mask & keep;
        return r;
    }

    // foreach
    int opApply(scope int delegate(Class c) dg)
    {
        int r;
        foreach (v; 0 .. length)
        {
            r = dg(opIndex(v));
            if (r)
                break;
        }
        return r;
    }
}
