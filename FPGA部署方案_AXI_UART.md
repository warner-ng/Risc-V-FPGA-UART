# RISC-V + Zynq PS/PL 协同方案
## 基于 AXI UART 16550 的通信架构

---

## 🎯 新架构设计

```
┌─────────────────────────────────────────────────────────────┐
│                    PC (串口助手/Python)                        │
└──────────────────┬──────────────────────────────────────────┘
                   │ UART (115200)
                   │
┌──────────────────▼──────────────────────────────────────────┐
│                  FPGA (Zynq 7021)                            │
│                                                              │
│  ┌─────────────────────────────────────────────────┐       │
│  │             PL (可编程逻辑)                        │       │
│  │                                                   │       │
│  │  ┌──────────────────┐      ┌─────────────────┐  │       │
│  │  │  AXI UART 16550  │◄────►│  RISC-V CPU     │  │       │
│  │  │     IP 核        │ AXI  │  + 指令内存     │  │       │
│  │  └────┬─────────────┘      │  + 数据内存     │  │       │
│  │       │ uart_tx/rx         └─────────────────┘  │       │
│  │       │                              ▲           │       │
│  └───────┼──────────────────────────────┼───────────┘       │
│          │                              │                    │
│          │ 物理引脚                     │ AXI 总线           │
│          │                              │                    │
│  ┌───────▼──────────────────────────────┼───────────┐       │
│  │              PS (ARM Cortex-A9)      │           │       │
│  │                                      │           │       │
│  │  ┌──────────────────┐       ┌───────▼────────┐  │       │
│  │  │  C 程序控制      │       │   AXI 总线     │  │       │
│  │  │  - 接收 PC 命令  │       │   Interconnect │  │       │
│  │  │  - 控制 RISC-V   │       └────────────────┘  │       │
│  │  │  - 读写 UART     │                           │       │
│  │  └──────────────────┘                           │       │
│  └──────────────────────────────────────────────────┘       │
└──────────────────────────────────────────────────────────────┘
```

---

## 📋 工作流程

### 1. PC → PS (通过 PS UART0)
```
PC 发送命令到 PS 的调试串口
PS 的 C 程序解析命令
```

### 2. PS → PL UART (通过 AXI 总线)
```
PS 通过 AXI 总线写入机器码到 PL UART 16550
PL UART 发送数据给外部设备（可选）
```

### 3. PS → PL RISC-V (通过 AXI 总线)
```
PS 通过 AXI 总线控制 RISC-V：
  - 写入指令内存
  - 启动执行
  - 读取结果
```

---

## 🔧 Vivado 硬件设计步骤

### 第一步：创建 Block Design

1. **新建 Vivado 工程**
   - 选择 RTL Project
   - 选择器件：xc7z021clg400-2

2. **创建 Block Design**
   ```
   Create Block Design → 命名为 "system"
   ```

3. **添加 ZYNQ7 Processing System**
   ```
   Add IP → ZYNQ7 Processing System
   Run Block Automation（自动配置）
   ```

4. **配置 PS**
   
   双击 ZYNQ7 PS IP，进行配置：

   **a) 使能串口 UART0（用于 PS 调试）**
   ```
   MIO Configuration → I/O Peripherals → UART 0 → 勾选
   ```

   **b) 配置 DDR**
   ```
   DDR Configuration → （保持默认或根据板子配置）
   ```

   **c) 配置时钟（给 PL 提供时钟）**
   ```
   Clock Configuration → PL Fabric Clocks → FCLK_CLK0 → 勾选
   设置频率：50MHz（根据你的需求）
   ```

   **d) 使能中断（用于 UART 中断）**
   ```
   Interrupts → Fabric Interrupts → PL-PS Interrupt Ports → 
   IRQ_F2P[15:0] → 勾选
   ```

5. **添加 AXI UART 16550 IP 核**
   ```
   Add IP → AXI UART 16550
   ```

6. **连接 IP 核**

   **a) Run Connection Automation**
   ```
   点击顶部的 "Run Connection Automation"
   自动连接 AXI 总线和时钟/复位
   ```

   **b) 手动连接中断**
   ```
   将 AXI UART 16550 的 ip2intc_irpt 连接到 ZYNQ PS 的 IRQ_F2P[0:0]
   ```

   **c) 引出 UART 信号**
   ```
   右键 AXI UART 16550 的 sin/sout → Make External
   自动生成 sin_0 和 sout_0 外部端口
   ```

7. **添加 RISC-V 模块（可选 - 如果要集成）**
   
   如果要将 RISC-V 也通过 AXI 控制：
   ```
   Add Module → 添加你的 RISC-V 顶层模块
   将其包装为 AXI Slave（需要添加 AXI 接口）
   ```

8. **验证设计**
   ```
   Tools → Validate Design (F6)
   ```

9. **生成 HDL Wrapper**
   ```
   右键 Block Design → Create HDL Wrapper
   选择 "Let Vivado manage wrapper and auto-update"
   ```

---

## 📝 约束文件（XDC）

创建 `pins.xdc`：

```tcl
# ========================================
# 系统时钟和复位
# ========================================
# 板载晶振时钟（根据你的板子修改引脚）
set_property PACKAGE_PIN [你的时钟引脚] [get_ports sys_clk]
set_property IOSTANDARD LVCMOS33 [get_ports sys_clk]

# 复位按键（根据你的板子修改引脚）
set_property PACKAGE_PIN [你的复位引脚] [get_ports sys_rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports sys_rst_n]

# ========================================
# PL UART 引脚 (连接到外部 USB-UART)
# ========================================
# 查看板子原理图，找到 UART 或 COM2 的引脚
# 文章中使用的是 K14 和 M15（正点原子板子）
set_property PACKAGE_PIN K14 [get_ports sin_0]
set_property PACKAGE_PIN M15 [get_ports sout_0]
set_property IOSTANDARD LVCMOS33 [get_ports sin_0]
set_property IOSTANDARD LVCMOS33 [get_ports sout_0]

# ========================================
# LED 指示灯（可选，用于调试）
# ========================================
set_property PACKAGE_PIN [LED0引脚] [get_ports led[0]]
set_property PACKAGE_PIN [LED1引脚] [get_ports led[1]]
set_property IOSTANDARD LVCMOS33 [get_ports led]
```

**注意**：
- 你需要根据你的板子原理图修改 `PACKAGE_PIN`
- `sin_0` 是接收引脚（RX）
- `sout_0` 是发送引脚（TX）

---

## 💻 SDK C 代码（PS 端）

### main.c

```c
#include "xparameters.h"
#include "xuartns550.h"
#include "xil_exception.h"
#include "xscugic.h"
#include "xil_printf.h"
#include "sleep.h"

// ========================================
// 参数定义
// ========================================
#define UART_DEVICE_ID      XPAR_UARTNS550_0_DEVICE_ID
#define UART_IRPT_INTR      XPAR_FABRIC_AXI_UART16550_0_IP2INTC_IRPT_INTR
#define INTC_DEVICE_ID      XPAR_SCUGIC_SINGLE_DEVICE_ID

// RISC-V 控制命令（根据你的协议定义）
#define CMD_LOAD_CODE       0x10
#define CMD_RUN             0x20
#define CMD_GET_RESULT      0x30
#define ACK                 0x06
#define DONE                0x0F

// ========================================
// 全局变量
// ========================================
XUartNs550 UartInstance;
XScuGic IntcInstance;

u8 RecvBuffer[256];
volatile int BytesReceived = 0;
volatile int DataReady = 0;

// ========================================
// 函数声明
// ========================================
void UartIntrHandler(void *CallBackRef, u32 Event, unsigned int EventData);
int SetupInterruptSystem(XScuGic *IntcInstancePtr, XUartNs550 *UartInstancePtr, u16 UartIntrId);
void SendByte(u8 byte);
void SendBytes(u8 *data, int len);
void ProcessCommand(u8 cmd);

// ========================================
// 主函数
// ========================================
int main(void)
{
    int Status;
    u16 Options;

    xil_printf("\r\n========================================\r\n");
    xil_printf("  RISC-V UART Control System\r\n");
    xil_printf("========================================\r\n");

    // 初始化 UART
    Status = XUartNs550_Initialize(&UartInstance, UART_DEVICE_ID);
    if (Status != XST_SUCCESS) {
        xil_printf("UART 初始化失败!\r\n");
        return XST_FAILURE;
    }

    // 自检
    Status = XUartNs550_SelfTest(&UartInstance);
    if (Status != XST_SUCCESS) {
        xil_printf("UART 自检失败!\r\n");
        return XST_FAILURE;
    }

    // 设置中断系统
    Status = SetupInterruptSystem(&IntcInstance, &UartInstance, UART_IRPT_INTR);
    if (Status != XST_SUCCESS) {
        xil_printf("中断设置失败!\r\n");
        return XST_FAILURE;
    }

    // 设置中断处理函数
    XUartNs550_SetHandler(&UartInstance, UartIntrHandler, &UartInstance);

    // 配置 UART 选项：使能中断、使能 FIFO
    Options = XUN_OPTION_DATA_INTR | XUN_OPTION_FIFOS_ENABLE | XUN_OPTION_RESET_TX_FIFO;
    XUartNs550_SetOptions(&UartInstance, Options);

    xil_printf("系统初始化完成\r\n");
    xil_printf("等待 PC 命令...\r\n\r\n");

    // 发送启动消息（类似原来的 "RV\n"）
    SendByte('R');
    SendByte('V');
    SendByte('\n');

    // 主循环
    while (1) {
        if (DataReady) {
            DataReady = 0;
            
            // 处理接收到的命令
            if (BytesReceived > 0) {
                u8 cmd = RecvBuffer[0];
                ProcessCommand(cmd);
                BytesReceived = 0;
            }
        }
        
        // 可以在这里添加其他任务
        usleep(1000);  // 1ms 延时
    }

    return XST_SUCCESS;
}

// ========================================
// 命令处理函数
// ========================================
void ProcessCommand(u8 cmd)
{
    xil_printf("收到命令: 0x%02X\r\n", cmd);

    switch (cmd) {
        case CMD_LOAD_CODE:
            xil_printf("处理 LOAD_CODE 命令\r\n");
            // TODO: 接收代码长度
            // TODO: 接收机器码
            // TODO: 写入 RISC-V 指令内存
            SendByte(ACK);  // 发送确认
            break;

        case CMD_RUN:
            xil_printf("处理 RUN 命令\r\n");
            // TODO: 启动 RISC-V 执行
            // TODO: 等待执行完成
            SendByte(DONE);  // 发送完成信号
            break;

        case CMD_GET_RESULT:
            xil_printf("处理 GET_RESULT 命令\r\n");
            // TODO: 从 RISC-V 读取结果
            // TODO: 发送结果（4字节）
            u8 result[4] = {0x2C, 0x01, 0x00, 0x00};  // 示例：300
            SendBytes(result, 4);
            break;

        default:
            xil_printf("未知命令\r\n");
            break;
    }
}

// ========================================
// UART 中断处理函数
// ========================================
void UartIntrHandler(void *CallBackRef, u32 Event, unsigned int EventData)
{
    // 接收到数据
    if (Event == XUN_EVENT_RECV_DATA) {
        // 读取接收到的数据
        BytesReceived = XUartNs550_Recv(&UartInstance, RecvBuffer, 1);
        
        // 回显（调试用）
        XUartNs550_Send(&UartInstance, RecvBuffer, BytesReceived);
        
        DataReady = 1;
        
        xil_printf("接收: 0x%02X\r\n", RecvBuffer[0]);
    }

    // 数据发送完成
    if (Event == XUN_EVENT_SENT_DATA) {
        // xil_printf("发送完成\r\n");
    }

    // 接收超时
    if (Event == XUN_EVENT_RECV_TIMEOUT) {
        xil_printf("接收超时\r\n");
    }
}

// ========================================
// 发送单个字节
// ========================================
void SendByte(u8 byte)
{
    XUartNs550_Send(&UartInstance, &byte, 1);
}

// ========================================
// 发送多个字节
// ========================================
void SendBytes(u8 *data, int len)
{
    XUartNs550_Send(&UartInstance, data, len);
}

// ========================================
// 中断系统设置
// ========================================
int SetupInterruptSystem(XScuGic *IntcInstancePtr, XUartNs550 *UartInstancePtr, u16 UartIntrId)
{
    int Status;
    XScuGic_Config *IntcConfig;

    // 初始化中断控制器
    IntcConfig = XScuGic_LookupConfig(INTC_DEVICE_ID);
    if (NULL == IntcConfig) {
        return XST_FAILURE;
    }

    Status = XScuGic_CfgInitialize(IntcInstancePtr, IntcConfig, IntcConfig->CpuBaseAddress);
    if (Status != XST_SUCCESS) {
        return XST_FAILURE;
    }

    // 设置优先级和触发类型
    XScuGic_SetPriorityTriggerType(IntcInstancePtr, UartIntrId, 0xA0, 0x3);

    // 连接中断处理函数
    Status = XScuGic_Connect(IntcInstancePtr, UartIntrId,
                             (Xil_ExceptionHandler)XUartNs550_InterruptHandler,
                             UartInstancePtr);
    if (Status != XST_SUCCESS) {
        return Status;
    }

    // 使能中断
    XScuGic_Enable(IntcInstancePtr, UartIntrId);

    // 初始化异常表
    Xil_ExceptionInit();

    // 注册中断控制器处理函数
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_INT,
                                  (Xil_ExceptionHandler)XScuGic_InterruptHandler,
                                  IntcInstancePtr);

    // 使能异常
    Xil_ExceptionEnable();

    return XST_SUCCESS;
}
```

---

## 🚀 完整部署流程

### 1. Vivado 部分

```
1. 创建工程 → 选择 xc7z021
2. 创建 Block Design
3. 添加 ZYNQ PS、AXI UART 16550
4. 连接 AXI 总线、中断、时钟
5. 引出 UART 引脚
6. 创建约束文件（根据板子原理图）
7. Generate Bitstream
8. Export Hardware (Include Bitstream)
```

### 2. SDK 部分

```
1. Launch SDK
2. File → New → Application Project
3. 输入项目名称
4. 选择 "Empty Application" 模板
5. 将上面的 main.c 代码复制到项目中
6. Build Project
7. Program FPGA
8. Run As → Launch on Hardware
```

### 3. PC 端测试

使用串口助手：
- **COM1**：连接 PS 的 UART0（调试串口，查看 xil_printf 输出）
- **COM2**：连接 PL 的 UART（与 RISC-V 通信）

或使用 Python 脚本（见之前的部署指南）

---

## 📊 与原方案对比

| 项目 | 原方案（纯 PL） | 新方案（PS + PL） |
|------|----------------|------------------|
| **控制方式** | PC 直接控制 PL UART | PC → PS → PL |
| **软件开发** | 不需要 | 需要 C 代码 |
| **灵活性** | 低 | 高（可扩展功能） |
| **调试** | 困难 | 容易（PS 端 printf） |
| **性能** | 高（直连） | 略低（多一跳） |

---

## ✅ 优势

1. **PS 端可以调试**：通过 xil_printf 查看运行状态
2. **灵活控制**：PS 可以动态控制 RISC-V 和 UART
3. **功能扩展**：可以添加更多 IP 核（GPIO、SPI 等）
4. **成熟方案**：参考 Xilinx 官方示例

---

## 📚 参考资料

- [CSDN 文章：ZYNQ PL 添加 IP 串口 UART AXI UART16550](https://blog.csdn.net/baidu_41704597/article/details/122028399)
- Xilinx UG585：Zynq-7000 Technical Reference Manual
- PG143：AXI UART 16550 LogiCORE IP Product Guide

---

## 🔧 下一步工作

1. 查找你的板子原理图，确定 UART 引脚
2. 在 Vivado 中按照上述步骤创建 Block Design
3. 修改约束文件中的引脚编号
4. 在 SDK 中完善 C 代码的 TODO 部分
5. 测试通信
