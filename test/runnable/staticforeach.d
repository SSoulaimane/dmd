// REQUIRED_ARGS:

void test1()
{    
    static void fun(int, int) {}

    static immutable int[5] a = [1, 2, 3, 4, 5];
    static foreach(i, v; a)
        fun(i, v);
}

/**********************************/
// https://issues.dlang.org/show_bug.cgi?id=19479

mixin template genInts19479a()
{
    static foreach (t; 0..1)
        int i = 5;
}

mixin template genInts19479b()
{
    static foreach (t; 0..2)
        mixin("int i" ~ cast(char)('0' + t) ~ " = 5;");
}

void test19479()
{
    {
        static foreach (t; 0..1)
            int i = 5;
        assert(i == 5);
    }
    {
        mixin genInts19479a!();
        assert(i == 5);
    }
    {
        static foreach (t; 0..2)
            mixin("int i" ~ cast(char)('0' + t) ~ " = 5;");
        assert(i0 == 5);
        assert(i1 == 5);
    }
    {
        mixin genInts19479b!();
        assert(i0 == 5);
        assert(i1 == 5);
    }
}

void main()
{
    test1();
    test19479();
}
