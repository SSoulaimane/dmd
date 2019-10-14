// REQUIRED_ARGS: -preview=rvaluetype

int cpCtor;
int mvCtor;

struct A
{
    this(inout ref A) inout { ++cpCtor; }
    this(inout @rvalue ref A) inout { ++ mvCtor; }
}

struct S
{
    A a;
}

S gs;
A ga;

T getValue(T)() { return T(); }
ref T getRef(T)()
{
    static if (is(T == S)) return gs;
    else return ga;
}
ref @rvalue(T) getRvalueRef(T)()
{
    static if (is(T == S))
        return cast(@rvalue)gs;
    else
        return cast(@rvalue)ga;
}

void test(T)()
{
    cpCtor = mvCtor = 0;
    T a;
    auto b = a; // cop
    assert(cpCtor == 1 && mvCtor == 0);
    auto c = cast(@rvalue)a; // move
    assert(cpCtor == 1 && mvCtor == 1);

    cpCtor = mvCtor = 0;
    auto d = getValue!T(); // nrvo
    assert(cpCtor == 0 && mvCtor == 0);
    auto e = getRef!T(); // copy
    assert(cpCtor == 1 && mvCtor == 0);
    auto f = getRvalueRef!T(); // move
    assert(cpCtor == 1 && mvCtor == 1);
}

struct S2
{
    static int i;
    this(@rvalue ref S2) { ++i; }
}

void func(S2) {}

void test2()
{
    S2 a = S2();
    assert(a.i == 0);
    func(S2());
    assert(a.i == 0);
    func(cast(@rvalue)a);
    assert(a.i == 1);
    S2 b = cast(@rvalue)a;
    assert(a.i == 2);
}

void main()
{
    test!A();
    test!S();
    test2();
}
