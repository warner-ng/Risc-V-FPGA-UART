# RISC-V UART 系统 FPGA 部署指南

## 📋 概述

本指南说明如何将仿真验证的 RISC-V UART 系统部署到真实的 FPGA 硬件上，使用真实的串口通信替代模拟环境。

---

## 🎯 部署目标

```
仿真环境 (Icarus Verilog)  →  真实硬件 (FPGA)
     ↓                              ↓
模拟串口通信                    真实 UART 通信
测试平台发送                    PC 串口助手发送
虚拟时钟                        FPGA 板载时钟
```

---

## 📊 主要区别对比

| 项目 | 仿真环境 | FPGA 硬件 |
|------|---------|----------|
| **时钟源** | testbench 生成 | 板载晶振（如 50MHz/100MHz） |
| **UART** | 模拟任务 | 真实 UART TX/RX 引脚 |
| **波特率** | 加速（BAUD_DIV=10） | 实际波特率（BAUD_DIV=434@50MHz） |
| **复位** | testbench 控制 | 板载按键 |
| **通信对象** | testbench | PC 串口助手/Python 脚本 |
| **调试** | $display 输出 | LED 指示/ILA 逻辑分析仪 |
| **验证** | 波形文件 | 实际运行结果 |

---

## 🔧 需要修改的内容

### 1. 去除仿真加速宏

**文件**: `riscvsingle_dynamic_load.v`

**修改位置**: UART 模块的波特率分频参数

```verilog
// 仿真版本（加速）
`ifdef SIM_FAST
parameter BAUD_DIV = 10;
`else
parameter BAUD_DIV = 434;  // 115200@50MHz
`endif

// FPGA 版本（直接使用实际值）
parameter BAUD_DIV = 434;  // 根据你的时钟频率调整
```

**波特率计算公式**:
```
BAUD_DIV = 系统时钟频率 / 波特率

例如:
- 50MHz, 115200 bps:  BAUD_DIV = 50,000,000 / 115,200 ≈ 434
- 100MHz, 115200 bps: BAUD_DIV = 100,000,000 / 115,200 ≈ 868
- 50MHz, 9600 bps:    BAUD_DIV = 50,000,000 / 9,600 ≈ 5208
```

### 2. 创建约束文件 (XDC)

**文件**: `uart_pins.xdc` （新建）

**需要定义的引脚**:
- 系统时钟 (sys_clk)
- 复位按键 (key)
- UART TX (uart_tx)
- UART RX (uart_rx)
- LED 指示灯 (led[1:0])

**示例内容**:
```tcl
# 时钟约束 (根据你的板子修改)
create_clock -period 20.000 [get_ports sys_clk]  # 50MHz

# 引脚位置约束 (根据你的板子原理图修改)
set_property PACKAGE_PIN Y9 [get_ports sys_clk]
set_property PACKAGE_PIN P16 [get_ports key]
set_property PACKAGE_PIN D18 [get_ports uart_tx]
set_property PACKAGE_PIN C17 [get_ports uart_rx]
set_property PACKAGE_PIN T22 [get_ports {led[0]}]
set_property PACKAGE_PIN T21 [get_ports {led[1]}]

# IO 标准
set_property IOSTANDARD LVCMOS33 [get_ports sys_clk]
set_property IOSTANDARD LVCMOS33 [get_ports key]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rx]
set_property IOSTANDARD LVCMOS33 [get_ports led]
```

### 3. 时钟管理（可选但推荐）

如果需要更稳定的时钟，可以使用 Xilinx Clock Wizard IP:
- 输入：板载时钟
- 输出：50MHz 或 100MHz
- 带锁定指示信号

### 4. 删除仿真专用代码

移除 testbench 文件，只保留设计文件：
- ✅ 保留: `riscvsingle_dynamic_load.v`
- ❌ 不添加: `riscv_dynamic_tb.v`

---

## 🚀 部署流程概览

### 第一步：Vivado 工程创建

1. **创建新工程**
   - 选择 RTL Project
   - 选择你的 FPGA 型号（如 xc7z020clg484-2）

2. **添加设计文件**
   - 添加 `riscvsingle_dynamic_load.v`
   - 设置 `fpga_top_dynamic` 为顶层模块

3. **添加约束文件**
   - 创建 XDC 文件
   - 根据板卡原理图配置引脚

4. **综合与实现**
   - Run Synthesis
   - Run Implementation
   - Generate Bitstream

5. **下载到 FPGA**
   - 连接 JTAG
   - Program Device

### 第二步：PC 端通信程序

有两种方式与 FPGA 通信：

#### 方式 1: 串口助手（简单测试）
- 使用串口调试助手（如 SSCOM、Putty、cutecom）
- 配置：115200, 8N1
- 手动发送十六进制命令

#### 方式 2: Python 脚本（推荐）
- 使用现有的 `ps_uart_controller.c` 逻辑
- 改写为 Python pyserial 脚本
- 自动化发送指令和接收结果

### 第三步：测试验证

1. **连接硬件**
   - FPGA 通过 USB-UART 连接到 PC
   - 确认 COM 口号

2. **发送测试指令**
   - 启动后 FPGA 发送 "RV\n"
   - PC 发送加载命令和机器码
   - PC 发送运行命令
   - PC 读取结果

3. **观察 LED**
   - LED[0]: CPU 运行状态
   - LED[1]: 分支跳转指示

---

## 📦 需要的工具和资源

### 开发工具
- ✅ **Vivado Design Suite** (2019.1 或更高)
- ✅ **FPGA 板卡** (Zynq-7000 或其他 Xilinx FPGA)
- ✅ **JTAG 下载器** (通常板卡自带)

### 通信工具
- **串口调试助手**: SSCOM, Putty, Tera Term
- **Python**: pyserial 库 (`pip install pyserial`)
- **驱动程序**: USB-UART 桥接芯片驱动（CH340, CP2102, FTDI）

### 参考文档
- 你的 FPGA 板卡原理图（确定引脚）
- Vivado 用户指南
- UART 规格书

---

## 🔍 关键配置参数

### 系统参数
```verilog
// 时钟频率
parameter CLK_FREQ = 50_000_000;  // 50 MHz

// UART 波特率
parameter BAUD_RATE = 115200;

// 波特率分频
parameter BAUD_DIV = CLK_FREQ / BAUD_RATE;  // 434

// 指令内存大小
parameter IMEM_SIZE = 64;  // 64 条指令 (256 字节)
```

### UART 配置
```
波特率: 115200 bps
数据位: 8 bit
停止位: 1 bit
奇偶校验: None
流控: None
```

---

## 🐛 常见问题和解决方案

### 1. 串口无响应
**可能原因**:
- COM 口选择错误
- 波特率设置不匹配
- TX/RX 接反
- FPGA 未正确下载

**解决方法**:
- 检查设备管理器中的 COM 口
- 验证 XDC 引脚配置
- 交换 TX/RX 尝试
- LED 指示灯是否工作

### 2. 接收数据乱码
**可能原因**:
- 波特率分频值不正确
- 时钟频率配置错误
- 信号完整性问题

**解决方法**:
- 重新计算 BAUD_DIV
- 使用 Clock Wizard IP
- 添加 UART 引脚的 PULLUP/PULLDOWN

### 3. CPU 不执行
**可能原因**:
- 复位信号极性错误
- 时钟未正确连接
- 指令加载失败

**解决方法**:
- 检查 key 信号（active high/low）
- 使用 ILA 查看内部信号
- LED 指示状态机

### 4. 结果不正确
**可能原因**:
- 机器码字节序错误
- 数据传输丢失
- CPU 时序问题

**解决方法**:
- 确认小端序传输
- 降低波特率测试（如 9600）
- 使用 ILA 调试 CPU

---

## 📝 Python 控制脚本框架

基于现有的 `ps_uart_controller.c` 逻辑，可以编写 Python 脚本：

```python
import serial
import time

# 配置串口
ser = serial.Serial(
    port='COM3',           # 修改为实际端口
    baudrate=115200,
    bytesize=8,
    parity='N',
    stopbits=1,
    timeout=1
)

# 等待 RISC-V 启动
print("等待 RISC-V 就绪...")
startup = ser.read(3)  # 读取 "RV\n"
if startup == b'RV\n':
    print("RISC-V 已就绪!")

# 发送加载命令
def load_code(instructions):
    cmd = bytes([0x10])  # CMD_LOAD_CODE
    length = len(instructions) * 4
    cmd += length.to_bytes(2, 'little')  # 长度（小端序）
    
    for instr in instructions:
        cmd += instr.to_bytes(4, 'little')  # 指令（小端序）
    
    ser.write(cmd)
    ack = ser.read(1)
    return ack == bytes([0x06])  # 检查 ACK

# 运行程序
def run_program():
    ser.write(bytes([0x20]))  # CMD_RUN
    done = ser.read(1)
    return done == bytes([0x0F])  # 检查 DONE

# 获取结果
def get_result():
    ser.write(bytes([0x30]))  # CMD_GET_RESULT
    result_bytes = ser.read(4)
    return int.from_bytes(result_bytes, 'little')

# 测试指令
instructions = [
    0x06400513,  # addi x10, x0, 100
    0x0C800593,  # addi x11, x0, 200
    0x00B50633,  # add x12, x10, x11
    0x00000013,  # nop
]

if load_code(instructions):
    print("代码加载成功!")
    if run_program():
        print("程序执行完成!")
        result = get_result()
        print(f"结果: x12 = {result}")

ser.close()
```

---

## 🎯 验证步骤

### 基础验证
1. ✅ FPGA 下载成功，LED 亮起
2. ✅ 串口连接成功，收到 "RV\n"
3. ✅ 发送命令有响应（ACK）
4. ✅ 简单指令执行正确

### 功能验证
1. ✅ 加载 4 条测试指令
2. ✅ 执行得到正确结果（x12=300）
3. ✅ LED 指示状态正确
4. ✅ 可重复测试

### 扩展验证
1. ✅ 测试更复杂的指令序列
2. ✅ 测试不同波特率
3. ✅ 长时间稳定性测试
4. ✅ 多次复位测试

---

## 📚 相关文件清单

### 必需文件（FPGA）
- ✅ `riscvsingle_dynamic_load.v` - 主设计文件
- ✅ `uart_pins.xdc` - 引脚约束文件（需创建）
- ✅ Vivado 工程文件

### 可选文件（PC 端）
- ✅ Python 控制脚本（需编写）
- ✅ 串口助手配置文件
- ✅ 测试指令集

### 参考文件
- ✅ `README_UART.md` - UART 协议说明
- ✅ `仿真测试说明.md` - 功能参考
- ✅ `系统架构图解.md` - 系统架构
- ✅ 板卡原理图（硬件厂商提供）

---

## 🎓 调试建议

### 1. 逐步验证
- 先验证时钟和复位
- 再验证 UART 发送（只发 "RV\n"）
- 然后验证 UART 接收
- 最后验证完整功能

### 2. 使用 ILA
添加 Integrated Logic Analyzer 观察:
- 状态机状态
- UART 收发信号
- CPU PC 和指令
- 寄存器值

### 3. 降低复杂度
如果遇到问题：
- 降低波特率（9600）
- 减少指令数量
- 简化测试程序

### 4. LED 调试
利用板载 LED 显示：
- 状态机状态（二进制编码）
- 数据接收指示
- 错误指示

---

## 🔗 下一步

完成 FPGA 部署后，可以：

1. **功能扩展**
   - 支持更多 RISC-V 指令
   - 增加数据内存容量
   - 实现中断机制

2. **性能优化**
   - 提高时钟频率
   - 实现流水线
   - 优化数据通路

3. **应用开发**
   - 编写更复杂的测试程序
   - 实现特定算法（如排序、搜索）
   - 连接外设（GPIO、SPI 等）

4. **系统集成**
   - 集成到 Zynq PS 端
   - 使用 AXI 总线通信
   - 构建完整 SoC

---

## 📞 获取帮助

- **Xilinx 论坛**: https://forums.xilinx.com/
- **RISC-V 社区**: https://riscv.org/
- **FPGA4Fun UART**: https://www.fpga4fun.com/SerialInterface.html
- **项目仓库**: 查看 README 和 Issues

---

## ✅ 检查清单

部署前确认：

- [ ] Vivado 已安装并可用
- [ ] FPGA 板卡已连接
- [ ] 查阅板卡原理图，确定引脚
- [ ] 计算正确的波特率分频值
- [ ] 准备串口通信工具
- [ ] USB-UART 驱动已安装
- [ ] 测试指令已准备

部署后验证：

- [ ] Bitstream 生成成功
- [ ] FPGA 下载成功
- [ ] 串口连接成功
- [ ] 收到启动消息 "RV\n"
- [ ] 命令响应正常
- [ ] 测试结果正确
- [ ] 系统稳定运行

---

**祝部署顺利！** 🎉

有问题请参考 [README_UART.md](README_UART.md) 中的硬件部署章节。
