
/********************************************/

void test1()
{
    int a = 1;

    auto func(alias b)()
    {
        ++a;
        ++b;
    }

    int b = 1;
    func!b;
    assert(a == 2);
    assert(b == 2);

    auto dg = &func!b;
    dg();
    assert(a == 3);
    assert(b == 3);

    template TA(alias i) { int v = i; }
    mixin TA!a;
    assert(v == 3);

}

/********************************************/

struct S2
{
    int m;
    auto exec(alias f)()
    {
        f(m);
    }
}

void test2()
{
    int a = 1;

    auto set(alias b)(int c) { b = c; }

    S2(10).exec!(set!a)();
    assert(a == 10);

    auto dg = &S2(20).exec!(set!a);
    dg();
    assert(a == 20);
}

/********************************************/

struct S3
{
    int m;

    auto add(alias a)(int b)
    {
        return a + m + b;
    }

    auto inner(alias a)(int i)
    {
        class I
        {
            int n;
            this() { n = i; }
            auto add(int b)
            {
                return a + n + m + b;
            }
            auto add2(alias c)(int b)
            {
                return a + n + m + b + c;
            }
        }
        return new I;
    }
}

void test3()
{
    int a = 1;
    int b = 2;
    int c = 3;

    assert(S3(4).add!a(10) == 4+1+10);

    auto dg = &S3(4).add!a;
    assert(dg(11) == 4+1+11);

    auto i = S3(5).inner!a(6);

    assert(i.add(7) == 5+1+6+7);
    auto dg2 = &i.add;
    assert(dg2(8) == 5+1+6+8);

    assert(i.add2!b(7) == 5+1+6+7+2);
    auto dg3 = &i.add2!b;
    assert(dg3(8) == 5+1+6+8+2);

    // type checking
    auto o0 = S3(10);
    auto o1 = S3(11);
    alias T0 = typeof(o0.inner!a(1));
    alias T1 = typeof(o1.inner!a(1));
    alias T2 = typeof(o0.inner!a(1));
    static assert(!is(T0 == T1));
    static assert(is(T0 == T2));
}

/********************************************/

class C4
{
    int m = 10;
    static int s = 20;
    template A(alias a)
    {
        template B(alias b)
        {
            template C(alias c)
            {
                auto sum()
                {
                    return a + b + c + s + m;
                }
            }
        }
    }
}

void test4()
{
    auto a = 1;
    auto b = 2;
    auto c = 3;

    assert(new C4().A!a.B!b.C!c.sum() == 1+2+3+10+20);
}

/********************************************/

interface I5
{
    int get();
    int sub(alias v)()
    {
        return get() - v;
    }
}

class A5
{
    int m;
    this(int m)
    {
        this.m = m;
    }
    this() {}
}

class B5 : A5, I5
{
    this(alias i)()
    {
        super(i);
    }
    auto add(alias v)()
    {
        return super.m + v;
    }
    int get()
    {
        return m;
    }
    this() {}
}

void test5()
{
    int a = 4;
    int b = 2;
    auto o = new B5;
    o.__ctor!a;
    assert(o.m == 4);
    assert(o.add!b == 4+2);
    assert(o.sub!b == 4-2);
}

/********************************************/

struct A6
{
    int m;
    auto add(alias a)()
    {
        m += a;
    }
}

struct B6
{
    int i;
    A6 a;
    alias a this;
}

struct S6
{
    int j;
    B6 b;
    alias b this;
}

void test6()
{
    int a = 9;
    auto o = S6(1, B6(1, A6(10)));
    o.add!9();
    assert(o.b.a.m == 10+9);
}

/********************************************/

struct S7
{
    int m;
    auto add(alias f)(int a)
    {
        auto add(int b) { return a + b; }
        return exec2!(f, add)();
    }
    auto exec2(alias f, alias g)()
    {
        return g(f(m));
    }
}

void test7()
{
    int a = 10;
    auto o = S7(1);
    auto fun(int m) { return m + a; }
    assert(o.add!fun(20) == 1+10+20);
}

/********************************************/

struct S8
{
    int m;
    S8 getVal(alias a)()
    {
        return this;
    }
    ref getRef(alias a)()
    {
        return this;
    }
}

void test8()
{
    int a;
    auto s = S8(1);

    ++s.getVal!a().m;
    assert(s.m == 1);

    ++s.getRef!a().m;
    assert(s.m == 2);
}

/********************************************/

void main()
{
    test1();
    test2();
    test3();
    test4();
    test5();
    test6();
    test7();
    test8();
}
