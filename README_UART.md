# PS 发送机器码给 RISC-V 执行并返回结果

## 目标效果

```
┌─────────────────┐                      ┌─────────────────┐
│    PS (ARM)     │   ── 发送机器码 ──>  │   RISC-V (PL)   │
│                 │                      │                 │
│   C 程序控制    │   <── 返回结果 ──    │   执行机器码    │
└─────────────────┘                      └─────────────────┘
```

---

## 示例：计算 100 + 200 = 300

| 指令 | 机器码 | 说明 |
|------|--------|------|
| `addi x10, x0, 100` | `0x06400513` | x10 = 100 |
| `addi x11, x0, 200` | `0x0C800593` | x11 = 200 |
| `add  x12, x10, x11` | `0x00B50633` | x12 = x10 + x11 = 300 |
| `nop` | `0x00000013` | 结束标记 |

**结果**: x12 = 300，通过 UART 返回给 PS

---

# 部署步骤

## 第一步：Vivado 硬件工程

### 1.1 创建 Vivado 工程

1. 打开 Vivado，选择 **Create Project**
2. 选择项目名称和路径
3. 选择 **RTL Project**
4. 选择你的 FPGA 型号 (例如 xc7z020clg484-2)

### 1.2 添加设计文件

1. 点击 **Add Sources** → **Add or create design sources**
2. 添加文件: `riscvsingle_dynamic_load.v`
3. 确认 **fpga_top_dynamic** 被设置为顶层模块

### 1.3 创建约束文件 (.xdc)

1. 点击 **Add Sources** → **Add or create constraints**
2. 创建新文件，例如 `pins.xdc`
3. 添加以下内容 (根据你的板子修改引脚):

```tcl
# 时钟 (100MHz)
set_property PACKAGE_PIN Y9 [get_ports sys_clk]
set_property IOSTANDARD LVCMOS33 [get_ports sys_clk]
create_clock -period 10.000 -name sys_clk [get_ports sys_clk]

# 复位按键 (active low)
set_property PACKAGE_PIN T18 [get_ports key]
set_property IOSTANDARD LVCMOS33 [get_ports key]

# LED
set_property PACKAGE_PIN T22 [get_ports {led[0]}]
set_property PACKAGE_PIN T21 [get_ports {led[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]

# UART TX (RISC-V 发送 -> PS 接收)
set_property PACKAGE_PIN Y18 [get_ports uart_tx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx]

# UART RX (RISC-V 接收 <- PS 发送)
set_property PACKAGE_PIN Y19 [get_ports uart_rx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rx]
```

> ⚠️ **注意**: 引脚编号需要根据你实际使用的开发板修改！

### 1.4 综合与实现

1. 点击 **Run Synthesis**，等待完成
2. 点击 **Run Implementation**，等待完成
3. 点击 **Generate Bitstream**，等待完成

### 1.5 导出硬件

1. 点击 **File** → **Export** → **Export Hardware**
2. 勾选 **Include bitstream**
3. 导出为 `.xsa` 文件

---

## 第二步：Vitis/SDK 软件工程

### 2.1 创建平台工程

1. 打开 Vitis IDE
2. 选择 **File** → **New** → **Platform Project**
3. 选择刚才导出的 `.xsa` 文件
4. 等待平台生成完成

### 2.2 创建应用工程

1. 选择 **File** → **New** → **Application Project**
2. 选择刚才创建的平台
3. 选择 **standalone** 操作系统
4. 选择 **Empty Application** 模板

### 2.3 添加源代码

1. 右键点击 `src` 文件夹 → **New** → **File**
2. 创建 `main.c`
3. 粘贴以下代码:

```c
#include <stdio.h>
#include "xuartlite.h"
#include "xparameters.h"

#define CMD_LOAD_CODE   0x10
#define CMD_RUN         0x20
#define CMD_GET_RESULT  0x30
#define ACK             0x06
#define DONE            0x0F

XUartLite UartLite;

void uart_send(u8 data) {
    while (XUartLite_Send(&UartLite, &data, 1) == 0);
}

u8 uart_recv(void) {
    u8 data;
    while (XUartLite_Recv(&UartLite, &data, 1) == 0);
    return data;
}

int load_program(u32 *code, int num_instructions) {
    int i;
    u16 byte_count = num_instructions * 4;
    
    uart_send(CMD_LOAD_CODE);
    uart_send(byte_count & 0xFF);
    uart_send((byte_count >> 8) & 0xFF);
    
    for (i = 0; i < num_instructions; i++) {
        uart_send((code[i] >> 0)  & 0xFF);
        uart_send((code[i] >> 8)  & 0xFF);
        uart_send((code[i] >> 16) & 0xFF);
        uart_send((code[i] >> 24) & 0xFF);
    }
    
    return (uart_recv() == ACK) ? 0 : -1;
}

u32 run_and_get_result(void) {
    u8 b0, b1, b2, b3;
    
    uart_send(CMD_RUN);
    if (uart_recv() != DONE) return 0xFFFFFFFF;
    
    uart_send(CMD_GET_RESULT);
    b0 = uart_recv();
    b1 = uart_recv();
    b2 = uart_recv();
    b3 = uart_recv();
    
    return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0;
}

int main(void) {
    u32 result;
    
    // 要执行的程序: 计算 100 + 200
    u32 program[] = {
        0x06400513,  // addi x10, x0, 100
        0x0C800593,  // addi x11, x0, 200
        0x00B50633,  // add  x12, x10, x11
        0x00000013   // nop
    };
    
    xil_printf("=== PS 发送机器码给 RISC-V ===\r\n\r\n");
    
    // 初始化 UART
    XUartLite_Initialize(&UartLite, XPAR_AXI_UARTLITE_0_DEVICE_ID);
    
    // 等待 RISC-V 就绪
    xil_printf("[1] 等待 RISC-V 就绪...\r\n");
    while (uart_recv() != 'R');
    uart_recv();  // 'V'
    uart_recv();  // '\n'
    xil_printf("    OK\r\n");
    
    // 发送程序
    xil_printf("[2] 发送机器码 (4 条指令, 16 字节)...\r\n");
    if (load_program(program, 4) == 0) {
        xil_printf("    OK\r\n");
    } else {
        xil_printf("    FAILED\r\n");
        return -1;
    }
    
    // 执行
    xil_printf("[3] 执行程序...\r\n");
    result = run_and_get_result();
    if (result != 0xFFFFFFFF) {
        xil_printf("    OK\r\n");
    } else {
        xil_printf("    FAILED\r\n");
        return -1;
    }
    
    // 显示结果
    xil_printf("[4] 结果: x12 = %u\r\n", result);
    xil_printf("\r\n验证: 100 + 200 = %u  %s\r\n", 
               result, (result == 300) ? "[正确]" : "[错误]");
    
    return 0;
}
```

### 2.4 编译

1. 右键点击应用工程 → **Build Project**
2. 等待编译完成

---

## 第三步：硬件连接

### 3.1 Block Design 连接 (如果使用 AXI UartLite)

如果你使用 Zynq PS 通过 AXI UartLite 与 RISC-V 通信:

```
┌─────────────────────────────────────────────────────────────┐
│                       Block Design                          │
│                                                             │
│  ┌────────────┐      ┌──────────────┐      ┌─────────────┐ │
│  │  Zynq PS   │─────>│ AXI UartLite │      │ RISC-V      │ │
│  │            │ AXI  │              │      │ (RTL模块)   │ │
│  └────────────┘      │  tx ─────────│─────>│ uart_rx     │ │
│                      │  rx <────────│─────<│ uart_tx     │ │
│                      └──────────────┘      └─────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

**步骤:**
1. 在 Block Design 中添加 Zynq Processing System
2. 添加 AXI UartLite IP
3. 运行 Connection Automation 连接 AXI 接口
4. 将 RISC-V 添加为 RTL 模块
5. 手动连接:
   - `axi_uartlite_0/tx` → `fpga_top_dynamic/uart_rx`
   - `fpga_top_dynamic/uart_tx` → `axi_uartlite_0/rx`

### 3.2 独立外部连接 (如果使用外部 UART)

如果 RISC-V 的 UART 直接连接到外部引脚:
- 用 USB-UART 转接器连接
- 在 PC 上用串口工具发送机器码

---

## 第四步：运行测试

### 4.1 下载比特流

1. 连接 FPGA 开发板
2. 在 Vivado 中: **Open Hardware Manager** → **Program Device**
3. 或在 Vitis 中: 右键点击应用 → **Run As** → **Launch on Hardware**

### 4.2 查看输出

1. 打开串口终端 (波特率 115200)
2. 运行 PS 程序
3. 期望输出:

```
=== PS 发送机器码给 RISC-V ===

[1] 等待 RISC-V 就绪...
    OK
[2] 发送机器码 (4 条指令, 16 字节)...
    OK
[3] 执行程序...
    OK
[4] 结果: x12 = 300

验证: 100 + 200 = 300  [正确]
```

---

## 通信协议详解

### 命令格式

| 命令 | 代码 | 格式 |
|------|------|------|
| LOAD_CODE | 0x10 | `0x10 + [长度低8位] + [长度高8位] + [机器码字节...]` |
| RUN | 0x20 | `0x20` |
| GET_RESULT | 0x30 | `0x30` |

### 通信时序

```
PS                                          RISC-V
│                                              │
│  <──────────── 'R' 'V' '\n' ────────────────│ 上电就绪
│                                              │
│  0x10 ──────────────────────────────────────>│ LOAD_CODE
│  0x10 0x00 ─────────────────────────────────>│ 长度=16字节
│  0x13 0x05 0x40 0x06 ───────────────────────>│ 指令1 (小端序)
│  0x93 0x05 0x80 0x0C ───────────────────────>│ 指令2
│  0x33 0x06 0xB5 0x00 ───────────────────────>│ 指令3
│  0x13 0x00 0x00 0x00 ───────────────────────>│ 指令4 (NOP)
│  <──────────── 0x06 (ACK) ──────────────────│ 加载完成
│                                              │
│  0x20 ──────────────────────────────────────>│ RUN
│                                              │ [执行中...]
│  <──────────── 0x0F (DONE) ─────────────────│ 执行完成
│                                              │
│  0x30 ──────────────────────────────────────>│ GET_RESULT
│  <──────────── 0x2C 0x01 0x00 0x00 ─────────│ 返回 300 (小端序)
│                                              │
```

---

## 文件清单

| 文件 | 说明 |
|------|------|
| `riscvsingle_dynamic_load.v` | RISC-V Verilog 源码 (PL 端) |
| `ps_uart_controller.c` | PS 端 C 程序 |
| `README_UART.md` | 本文档 |

---

## 常见问题

### Q: RISC-V 没有响应 "RV\n"?

1. 检查复位按键是否正确连接
2. 检查时钟是否正确 (默认 100MHz)
3. 用 ILA 观察 `state` 信号

### Q: 收到 ACK 但执行没有返回 DONE?

1. 检查机器码是否正确
2. 确保最后一条是 NOP (`0x00000013`)
3. 检查 `cpu_run` 信号是否拉高

### Q: 返回结果不正确?

1. 确认结果存在 x12 寄存器
2. 检查机器码的小端序发送是否正确
