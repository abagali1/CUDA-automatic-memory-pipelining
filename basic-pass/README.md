"Hello World" llvm pass following this [guide](https://github.com/banach-space/llvm-tutor/tree/main)

```bash
export LLVM_DIR=<installation/dir/of/llvm/19>
mkdir cmake-build
cd cmake-build
cmake -DLT_LLVM_INSTALL_DIR=$LLVM_DIR ..
make
```

Generate input file:

```bash
$LLVM_DIR/bin/clang -O1 -S -emit-llvm input_hello_world.c -o input_hello_world.ll
```

Run HelloWorld with opt (use libHelloWorld.so on Linux and libHelloWorld.dylib on Mac OS):

```bash
$LLVM_DIR/bin/opt -load-pass-plugin ./libHelloWorld.{so|dylib} -passes=hello-world -disable-output input_hello_world.ll
```
