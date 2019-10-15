// REQUIRED_ARGS: -preview=rvaluetype

void test1()
{
    static char[] result;

    static struct A
    {
        this(inout ref A) inout { result ~= "Cc"; }
        this(inout @rvalue ref A) inout { result ~= "Mc"; }
    }

    static struct S
    {
        A a;
    }

    static S gs;
    static A ga;

    static T getValue(T)() { return T(); }
    static ref T getRef(T)()
    {
        static if (is(T == S)) return gs;
        else return ga;
    }
    static ref @rvalue(T) getRvalueRef(T)()
    {
        static if (is(T == S))
            return cast(@rvalue)gs;
        else
            return cast(@rvalue)ga;
    }

    static void test(T)()
    {
        result = null;
        T a;
        auto b = a; // Cc
        auto c = cast(@rvalue)a; // Mc
        assert(result == "CcMc");

        result = null;
        auto d = getValue!T(); // nrvo
        auto f = getRvalueRef!T(); // Mc
        auto e = getRef!T(); // Cc
        assert(result == "McCc");
    }

    test!A();
    test!S();
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

struct S3
{
    static char[] r;

    this(ref inout S3) inout { r ~= "Cc"; }
    this(@rvalue ref inout S3) inout { r ~= "Mc"; }
    void opAssign(ref inout S3) inout { r ~= "Ca"; }
    void opAssign(@rvalue ref inout S3) inout { r ~= "Ma"; }
    ~this() inout { r ~= "D"; }
}

S3 get3() { return S3(); }
void fun3(S3) {}

void test3()
{
    S3.r = null;
    {
        S3 a = get3();
        S3 b = a; // Cc
        S3 c = cast(@rvalue) b; // Mc
        b = get3(); // MaD
        b = c; // Ca
        a = cast(@rvalue) c; // Ma
        fun3(get3()); // D
        fun3(cast(@rvalue)b); // McD
        // DDD
    }
    assert(S3.r == "CcMcMaDCaMaDMcDDDD", S3.r);
}

struct A4
{
    static char[] r;

    this(@rvalue ref inout A4) inout { r ~= "Mc"; }
    this(this) { r ~= "Pb"; }
    ~this() { r ~= "D"; }
}

struct S4
{
    A4 a;
}

void test4()
{
    A4.r = null;
    A4 a;
    a = cast(@rvalue)a;
    assert(A4.r == "DMc", A4.r);

    A4.r = null;
    S4 b;
    b = cast(@rvalue) b;
    assert(A4.r == "DMc", A4.r);
}

void main()
{
    test1();
    test2();
    test3();
    test4();
}
