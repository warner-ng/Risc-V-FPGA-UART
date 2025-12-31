@echo off
echo ========================================
echo  RISC-V 动态加载仿真测试
echo ========================================
echo.

cd /d "%~dp0"

echo [1] 编译 Verilog 文件 (仿真加速模式)...
iverilog -DSIM_FAST -o riscv_dynamic_sim.vvp riscvsingle_dynamic_load.v riscv_dynamic_tb.v

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo 编译失败!
    pause
    exit /b 1
)

echo     编译成功!
echo.

echo [2] 运行仿真...
echo.
vvp riscv_dynamic_sim.vvp

echo.
echo [3] 仿真完成!
echo     波形文件: riscv_dynamic_test.vcd
echo     可用 GTKWave 查看: gtkwave riscv_dynamic_test.vcd
echo.
pause
