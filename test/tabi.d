import core.simd : long4;

extern (C) int printf(const char*, ...);

struct y { long4 a; }

y test1_out_y()
{
    y t;
    return t;
}

void main()
{
    printf( "Test1 out y\n" );
    test1_out_y();
}
