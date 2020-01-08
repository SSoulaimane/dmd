/*
REQUIRED_ARGS: -g
PERMUTE_ARGS:
GDB_SCRIPT:
---
b 21
r
printf "value=%d derived_value=%d\n", value, derived_value
---
GDB_MATCH: value=10 derived_value=20
*/

class Base { int value; }
class Derivative : Base
{
    int derived_value;
    void foo ()
    {
        assert(value == 10);
        assert(derived_value == 20);
        // BP
    }
}

void main ()
{
    auto d = new Derivative();
    d.value = 10;
    d.derived_value = 20;
    d.foo;
}
