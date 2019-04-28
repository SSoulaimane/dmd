// PERMUTE_ARGS: -release -g -mcpu=native

import core.simd;

version(Windows) {}
else version(X86_64)
{
        version = Run_X86_64_Tests;
}

version (D_AVX2)
{
        version = Run_AVX_Tests;
}

extern (C) int printf(const char*, ...);

template tuple(A...) { alias A tuple; }
enum bool isSIMDVector(T) = is(T : __vector(V[N]), V, size_t N);

alias byte   B;
alias short  S;
alias int    I;
alias long   L;
alias float  F;
alias double D;
alias real   R;

version (D_SIMD)
alias long2  X;

version (Run_AVX_Tests)
alias long4  Y;

// Single Type

struct b        { B a;                  }
struct bb       { B a,b;                }
struct bbb      { B a,b,c;              }
struct bbbb     { B a,b,c,d;            }
struct bbbbb    { B a,b,c,d, e;         }
struct b6       { B a,b,c,d, e,f;       }
struct b7       { B a,b,c,d, e,f,g;     }
struct b8       { B a,b,c,d, e,f,g,h;   }
struct b9       { B a,b,c,d, e,f,g,h, i;                }
struct b10      { B a,b,c,d, e,f,g,h, i,j;              }
struct b11      { B a,b,c,d, e,f,g,h, i,j,k;            }
struct b12      { B a,b,c,d, e,f,g,h, i,j,k,l;          }
struct b13      { B a,b,c,d, e,f,g,h, i,j,k,l, m;       }
struct b14      { B a,b,c,d, e,f,g,h, i,j,k,l, m,n;     }
struct b15      { B a,b,c,d, e,f,g,h, i,j,k,l, m,n,o;   }
struct b16      { B a,b,c,d, e,f,g,h, i,j,k,l, m,n,o,p; }
struct b17      { B a,b,c,d, e,f,g,h, i,j,k,l, m,n,o,p, q;      }
struct b18      { B a,b,c,d, e,f,g,h, i,j,k,l, m,n,o,p, q,r;    }
struct b19      { B a,b,c,d, e,f,g,h, i,j,k,l, m,n,o,p, q,r,s;  }
struct b20      { B a,b,c,d, e,f,g,h, i,j,k,l, m,n,o,p, q,r,s,t;}

struct s        { S a;                  }
struct ss       { S a,b;                }
struct sss      { S a,b,c;              }
struct ssss     { S a,b,c,d;            }
struct sssss    { S a,b,c,d, e;         }
struct s6       { S a,b,c,d, e,f;       }
struct s7       { S a,b,c,d, e,f,g;     }
struct s8       { S a,b,c,d, e,f,g,h;   }
struct s9       { S a,b,c,d, e,f,g,h, i;  }
struct s10      { S a,b,c,d, e,f,g,h, i,j;}

struct i        { I a;          }       struct l        { L a;          }
struct ii       { I a,b;        }       struct ll       { L a,b;        }
struct iii      { I a,b,c;      }       struct lll      { L a,b,c;      }
struct iiii     { I a,b,c,d;    }       struct llll     { L a,b,c,d;    }
struct iiiii    { I a,b,c,d,e;  }       struct lllll    { L a,b,c,d,e;  }

struct f        { F a;          }       struct d        { D a;          }
struct ff       { F a,b;        }       struct dd       { D a,b;        }
struct fff      { F a,b,c;      }       struct ddd      { D a,b,c;      }
struct ffff     { F a,b,c,d;    }       struct dddd     { D a,b,c,d;    }
struct fffff    { F a,b,c,d,e;  }       struct ddddd    { D a,b,c,d,e;  }

// Mixed Size

struct js       { I a;   S b;   }
struct iss      { I a;   S b,c; }
struct  si      { S a;   I b;   }
struct ssi      { S a,b; I c;   }
struct sis      { S a;   I b;  S c; }

struct ls       { L a;   S b;   }
struct lss      { L a;   S b,c; }
struct  sl      { S a;   L b;   }
struct ssl      { S a,b; L c;   }
struct sls      { S a;   L b;  S c; }

struct li       { L a;   I b;   }
struct lii      { L a;   I b,c; }
struct  il      { I a;   L b;   }
struct iil      { I a,b; L c;   }
struct ili      { I a;   L b;  I c; }

struct df       { D a;   F b;   }
struct dff      { D a;   F b,c; }
struct  fd      { F a;   D b;   }
struct ffd      { F a,b; D c;   }
struct fdf      { F a;   D b;  F c; }

// Mixed Types

struct fi       { F a;   I b;   }
struct fii      { F a;   I b,c; }
struct  jf      { I a;   F b;   }
struct iif      { I a,b; F c;   }
struct ifi      { I a;   F b;  I c; }

struct ffi      { F a,b; I c;           }
struct ffii     { F a,b; I c,d;         }
struct  iff     { I a;   F b,c;         }
struct iiff     { I a,b; F c,d;         }
struct ifif     { I a;   F b;  I c; F d;}

struct di       { D a;   I b;   }
struct dii      { D a;   I b,c; }
struct  id      { I a;   D b;   }
struct iid      { I a,b; D c;   }
struct idi      { I a;   D b;  I c; }

// Real ( long double )

struct r        { R a;          }
struct rr       { R a,b;        }
struct rb       { R a;   B b;   }
struct rf       { R a;   F b;   }
struct fr       { F a;   R b;   }
alias  c = creal;

// SIMD
version (D_SIMD)
{
struct x        { X a;          }
struct xx       { X a,b;        }
struct xb       { X a;   B b;   }
struct xf       { X a;   F b;   }
struct bx       { B a;   X b;   }

version (Run_AVX_Tests)
{
struct y        { Y a;          }
struct yy       { Y a,b;        }
struct yb       { Y a;   B b;   }
struct yf       { Y a;   F b;   }
struct by       { B a;   Y b;   }
} // Run_AVX_Tests
} // D_SIMD

                // Int Registers only
alias tuple!(   b,bb,bbb,bbbb,bbbbb,
                b6, b7, b8, b9, b10,
                b11,b12,b13,b14,b15,
                b16,b17,b18,b19,b20,
                s,ss,sss,ssss,sssss,
                s6, s7, s8, s9, s10,
                i,ii,iii,iiii,iiiii,
                l,ll,lll,llll,lllll,
                //
                js,iss,si,ssi, sis,
                ls,lss,sl,ssl, sls,
                li,lii,il,iil, ili,
                fi,fii,jf,ifi,ifif,                   // INT_END

                // SSE registers only
                f,ff,fff,ffff,fffff,
                d,dd,ddd,dddd,ddddd,
                //
                df,dff,fd,ffd, fdf,     // SSE_END

                // Int and SSE
                ffi,ffii,iff,iiff,iif,
                di,  dii,id, iid, idi,  // MIX_END
                // ---
            ) ALL_T;

enum INT_END = 60;
enum SSE_END = 75;
enum MIX_END = ALL_T.length;
enum R_END   = MIX_END + R_T.length;
enum V16_END = R_END + V16_T.length;
enum V32_END = V16_END + V32_T.length;
alias V_END  = V32_END;
alias ALL_END = V_END;

                // x87
alias tuple!(   r,rr,rb,rf,fr,c,
                // ---
            ) R_T;
//"r","rr","rb","rf","fr",

                // SIMD Vectors 16 bytes
version (D_SIMD)
        alias tuple!(
                x,xx,xb,xf,bx,
                // ---
            ) V16_T;
else
        alias V16_T = tuple!();

                // SIMD Vectors 32 bytes
version (Run_AVX_Tests)
        alias tuple!(
                y,yy,yb,yf,by,
                // ---
            ) V32_T;
else
        alias V32_T = tuple!();

alias V_T = tuple!( V16_T, V32_T, );

string[] ALL_S=[
                "b","bb","bbb","bbbb","bbbbb",
                "b6", "b7", "b8", "b9", "b10",
                "b11","b12","b13","b14","b15",
                "b16","b17","b18","b19","b20",
                "s","ss","sss","ssss","sssss",
                "s6","s7","s8","s9" , "s10",
                "i","ii","iii","iiii","iiiii",
                "l","ll","lll","llll","lllll",
                // ---
                "js","iss","si","ssi", "sis",
                "ls","lss","sl","ssl", "sls",
                "li","lii","il","iil", "ili",
                "fi","fii","jf", "ifi","ifif",
                // ---
                "f","ff","fff","ffff","fffff",
                "d","dd","ddd","dddd","ddddd",
                "df","dff","fd","ffd", "dfd",
                // ---
                "ffi","ffii","iff","iiff","iif",
                "di","dii","id","iid","idi",
                // ---
                "r","rr","rb","rf","fr","c",
                // ---
                "x","xx","xb","xf","bx",
                "y","yy","yb","yf","by",
               ];

/* ***********************************************************************
                                   All
 ************************************************************************/
// test1 Struct passing and return

int[ALL_END] results_1;

T test1_out(T)( )
{
        T t;
        foreach( i, ref e; t.tupleof )  e = i+1;
        return t;
}
T test1_inout(T)( T t)
{
        foreach( i, ref e; t.tupleof )  e += 10;
        return t;
}

T test1_out(T : creal)( )
{
        T t = 1+2i;
        return t;
}
T test1_inout(T : creal)( T t)
{
        return (t.re + 10) + (t.im + 10) * 1i;
}

void test1_call_out(T)( int n )
{
        T t1;
        foreach( i, ref e; t1.tupleof ) e = i+1;
        T t2 = test1_out!(T)();

        if( t1 == t2 ) results_1[n] |= 1;
}
void test1_call_inout(T)( int n )
{
        T t1;
        foreach( i, ref e; t1.tupleof ) e = i+1;
        T t2 = test1_inout!(T)( t1 );
        foreach( i, ref e; t1.tupleof ) e += 10;

        if( t1 == t2 ) results_1[n] |= 2;
}

void test1_call_out(T : creal)( int n )
{
        T t1 = 1+2i;
        T t2 = test1_out!(T)();

        if( t1 == t2 ) results_1[n] |= 1;
}
void test1_call_inout(T : creal)( int n )
{
        T t1 = 1+2i;
        T t2 = test1_inout!(T)( t1 );
        t1 = (t1.re + 10) + (t1.im + 10) * 1i;

        if( t1 == t2 ) results_1[n] |= 2;
}

void test1_call_out_vec(T)( int n )
{
        printf("test1_call_out_vec!%.*s\n", T.stringof.sizeof, T.stringof.ptr);
        T t1;
        foreach( i, ref e; t1.tupleof ) e = i+1;
        T t2 = test1_out!(T)();

        results_1[n] = 1;
        foreach( i, ref e; t1.tupleof )
        {
                static if (isSIMDVector!(typeof(e)))
                        results_1[n] &= e[] == t2.tupleof[i][];
                else
                        results_1[n] &= e == t2.tupleof[i];
        }
        printf("#\n");
}
void test1_call_inout_vec(T)( int n )
{
        printf("test1_call_inout_vec!%.*s\n", T.stringof.sizeof, T.stringof.ptr);
        T t1;
        foreach( i, ref e; t1.tupleof ) e = i+1;
        T t2 = test1_inout!(T)( t1 );
        foreach( i, ref e; t1.tupleof ) e += 10;

        bool r = true;
        foreach( i, ref e; t1.tupleof )
        {
                static if (isSIMDVector!(typeof(e)))
                        r &= e[] == t2.tupleof[i][];
                else
                        r &= e == t2.tupleof[i];
        }
        if( r ) results_1[n] |= 2;
        printf("#\n");
}

void D_test1( )
{
        // Run Tests
        //foreach( n, T; tuple!( ALL_T, R_T ) )
        //{
        //        test1_call_out!(T)(n);
        //        test1_call_inout!(T)(n);
        //}

        //results_1[R_END..V_END] = 0;
        //foreach( n, T; V_T )
        //{
        //        test1_call_out_vec!(T)( n + R_END );
        //        test1_call_inout_vec!(T)( n + R_END );
        //}

        printf("Running #1 Tests\n");

        version (Run_AVX_Tests)
        {
            printf("Running AVX Tests\n");

            if( ~results_1[0] & 1 ) {
                test1_call_out_vec!y( 0 );
                printf( "Test1   out y \tFail\n" );
                assert(0);
            }
            if( ~results_1[0] & 2 ) {
                //test1_call_inout_vec!y( 0 );
                printf( "Test1 inout y \tFail\n" );
                assert(0);
            }
        }

        //bool pass = true;
        //foreach( i, r; results_1 )
        //{
        //        if (i < R_END) continue;
        //        if( ~r & 1 )
        //        {
        //        pass = false;
        //        printf( "Test1   out %s \tFail\n", ALL_S[i].ptr );
        //        }
        //        if( ~r & 2 )
        //        {
        //        pass = false;
        //        printf( "Test1 inout %s \tFail\n", ALL_S[i].ptr );
        //        }
        //}
        //assert( pass );
}

/************************************************************************/
// based on runnable/test23.d : test44()
// Return Struct into an Array

struct S1
{       int i,j;

        static S1 foo(int x)
        {       S1 s;
                s.i = x;
                return s;
}       }
struct S2
{       int i,j,k;

        static S2 foo(int x)
        {       S2 s;
                s.i = x;
                return s;
}       }
struct S3
{       float i,j;

        static S3 foo(int x)
        {       S3 s;
                s.i = x;
                return s;
}       }
struct S4
{       float i,j,k;

        static S4 foo(int x)
        {       S4 s;
                s.i = x;
                return s;
}       }
struct S5
{       float i,j;
        int   k;

        static S5 foo(float x)
        {       S5 s;
                s.i = x;
                return s;
}       }

void D_test2()
{
        S1[] s1;
        S2[] s2;
        S3[] s3;
        S4[] s4;
        S5[] s5;

        s1 = s1 ~ S1.foo(6);    s1 = s1 ~ S1.foo(1);
        s2 = s2 ~ S2.foo(6);    s2 = s2 ~ S2.foo(1);
        s3 = s3 ~ S3.foo(6);    s3 = s3 ~ S3.foo(1);
        s4 = s4 ~ S4.foo(6);    s4 = s4 ~ S4.foo(1);
        s5 = s5 ~ S5.foo(6);    s5 = s5 ~ S5.foo(1);

        assert( s1.length == 2 );
        assert( s1[0].i == 6 );
        assert( s1[1].i == 1 );

        assert( s2.length == 2 );
        assert( s2[0].i == 6 );
        assert( s2[1].i == 1 );

        assert( s3.length == 2 );
        assert( s3[0].i == 6 );
        assert( s3[1].i == 1 );

        assert( s4.length == 2 );
        assert( s4[0].i == 6 );
        assert( s4[1].i == 1 );

        assert( s5.length == 2 );
        assert( s5[0].i == 6 );
        assert( s5[1].i == 1 );

}

/* ***********************************************************************
                                X86_64
 ************************************************************************/

version(Run_X86_64_Tests)
{} // end version(Run_X86_64_Tests)

/************************************************************************/


void main()
{
        printf("Main\n");
        D_test1();
        //D_test2();

        version(Run_X86_64_Tests)
        {
                test1();
                test2();
                test3();
                test4();
        }
}

/+
/**
 * C code to generate the table RegValue
 */
string c_generate_returns()
{
        string value =  " 1, 2, 3, 4, 5, 6, 7, 8, 9,10,"
                        "11,12,13,14,15,16,17,18,19,20,";

        string code = "#include \"cgen.h\"\n";

        // Generate return functions
        foreach( int n, T; ALL_T )
        {
                auto Ts  = T.stringof;
                auto len = T.tupleof.length;

                code ~= "struct "~Ts~" func_ret_"~Ts~"(void) { \n";
                code ~= "struct "~Ts~" x = { ";
                code ~= value[0..len*3] ~ " };\n";
                code ~= "return x;\n}\n";
        }
        return code;
}
string c_generate_pass()
{
        string value =  " 1, 2, 3, 4, 5, 6, 7, 8, 9,10,"
                        "11,12,13,14,15,16,17,18,19,20,";

        string code;

        // Generate return functions
        foreach( int n, T; ALL_T )
        {
                auto Ts  = T.stringof;
                auto len = T.tupleof.length;

                code ~= "void func_pass_"~Ts~"( struct "~Ts~" x ) {\n";
                ////////////////
                // Which type of compare
                static if(n < INT_END)
                        enum MODE = 1; // Int
                else static if(n < SSE_END)
                        enum MODE = 2; // Float
                else    enum MODE = 3; // Mix

                auto nn  = n.stringof;

                /* Begin */

                code ~= "asm(\n";
                final switch( MODE )
                {
                case 1:
                code ~= `"movq  %rdi, reg\n" "movq  %rsi, reg+8\n"`;
                break;
                case 2:
                code ~= `"movq %xmm0, reg\n" "movq %xmm1, reg+8\n"`;
                break;
                case 3:
                code ~= `"movq %xmm0, reg\n" "movq  %rdi, reg+8\n"`;
                }
                code ~= "\n);\n";
                code ~= "}\n";

                ////////////////
                code ~= "void func_call_"~Ts~"( void ) {\n";
                code ~= "struct "~Ts~" x = { ";
                code ~= value[0..len*3] ~ " };\n";
                code ~= "func_pass_"~Ts~"( x );\n}\n";
        }
        return code;
}
string c_generate_main()
{
        string code = "void main() {\n";

        foreach( int n, T; ALL_T )
        {
                // Which type of compare
                static if(n < INT_END)
                        enum MODE = 1; // Int
                else static if(n < SSE_END)
                        enum MODE = 2; // Float
                else    enum MODE = 3; // Mix

                auto nn  = n.stringof;
                auto Ts  = T.stringof;

                /* Begin */

                code ~= `printf("/* %3d  `~Ts~`\t*/ ", `~nn~`);`"\n";
                if( !(expected[n] & 1) )
                {
                        code ~= `printf("null,\n");`"\n";
                        continue;
                }
                code ~= "asm(\n";
                code ~= `"call func_ret_`~Ts~`\n"`"\n";
                final switch( MODE )
                {
                case 1:
                code ~= `"movq  %rax, reg\n" "movq  %rdx, reg+8\n"`;
                break;
                case 2:
                code ~= `"movq %xmm0, reg\n" "movq %xmm1, reg+8\n"`;
                break;
                case 3:
                code ~= `"movq %xmm0, reg\n" "movq  %rax, reg+8\n"`;
                }
                code ~= "\n);\n";

                code ~= `printf("[ 0x%016lx", reg.r1 );`"\n";

                if( T.sizeof > 8  || MODE == 3 )
                        code ~= `printf(", 0x%016lx ],\n", reg.r2 );`"\n";
                else    code ~= `printf(",   %015c  ],\n", ' '    );`"\n";
        }

        foreach( int n, T; ALL_T )
        {
                // Which type of compare
                static if(n < INT_END)
                        enum MODE = 1; // Int
                else static if(n < SSE_END)
                        enum MODE = 2; // Float
                else    enum MODE = 3; // Mix

                auto nn  = n.stringof;
                auto Ts  = T.stringof;

                /* Begin */

                code ~= `printf("/* %3d  `~Ts~`\t*/ ", `~nn~`);`"\n";
                if( !(expected[n] & 1) )
                {
                        code ~= `printf("null,\n");`"\n";
                        continue;
                }
                code ~= "func_call_"~Ts~"();\n";

                code ~= `printf("[ 0x%016lx", reg.r1 );`"\n";

                if( T.sizeof > 8  || MODE == 3 )
                        code ~= `printf(", 0x%016lx ],\n", reg.r2 );`"\n";
                else    code ~= `printf(",   %015c  ],\n", ' '    );`"\n";
        }


        return code ~ "}";
}
pragma(msg, c_generate_returns() );
pragma(msg, c_generate_pass() );
pragma(msg, c_generate_main() );
// +/

/+
/**
 * Generate Functions that pass/return each Struct type
 *
 * ( Easier to look at objdump this way )
 */
string d_generate_functions( )
{
        string code = "extern(C) {";

        // pass
        foreach( s; ALL_T )
        {
                string ss = s.stringof;

                code ~= "void func_in_"~ss~"( "~ss~" t ) { t.a = 12; }\n";
        }
        // return
        foreach( s; ALL_T[0..10] )
        {
                string ss = s.stringof;

                code ~= `
                auto func_out_`~ss~`()
                {
                        `~ss~` t;
                        foreach( i, ref e; t.tupleof )  e = i+1;
                        return t;
                }`;
        }
        // pass & return
        foreach( s; ALL_T[0..10] )
        {
                string ss = s.stringof;

                code ~= `
                auto func_inout_`~ss~`( `~ss~` t )
                {
                        foreach( i, ref e; t.tupleof )  e += 10;
                        return t;
                }`;
        }
        return code ~ "\n} // extern(C)\n";
}
//pragma( msg, d_generate_functions() );
mixin( d_generate_functions() );
// +/
