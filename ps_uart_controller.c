/**
 * PS 发送机器码给 RISC-V 执行
 * 用于 Zynq PS (ARM) 端
 */

#include <stdio.h>
#include <xuartlite.h>
#include <xparameters.h>

#define CMD_LOAD_CODE   0x10
#define CMD_RUN         0x20
#define CMD_GET_RESULT  0x30
#define ACK             0x06
#define DONE            0x0F

XUartLite UartLite;

//=============================================================================
// UART 基本操作
//=============================================================================
void uart_send(u8 data) {
    while (XUartLite_Send(&UartLite, &data, 1) == 0);
}

u8 uart_recv(void) {
    u8 data;
    while (XUartLite_Recv(&UartLite, &data, 1) == 0);
    return data;
}

//=============================================================================
// 发送机器码到 RISC-V
//=============================================================================
int load_program(u32 *code, int num_instructions) {
    int i;
    u16 byte_count = num_instructions * 4;
    
    // 发送命令
    uart_send(CMD_LOAD_CODE);
    
    // 发送长度 (2字节, 小端)
    uart_send(byte_count & 0xFF);
    uart_send((byte_count >> 8) & 0xFF);
    
    // 发送机器码 (每条指令4字节, 小端)
    for (i = 0; i < num_instructions; i++) {
        uart_send((code[i] >> 0)  & 0xFF);
        uart_send((code[i] >> 8)  & 0xFF);
        uart_send((code[i] >> 16) & 0xFF);
        uart_send((code[i] >> 24) & 0xFF);
    }
    
    // 等待确认
    return (uart_recv() == ACK) ? 0 : -1;
}

//=============================================================================
// 执行程序
//=============================================================================
int run_program(void) {
    uart_send(CMD_RUN);
    return (uart_recv() == DONE) ? 0 : -1;
}

//=============================================================================
// 获取结果 (x12 寄存器)
//=============================================================================
u32 get_result(void) {
    u8 b0, b1, b2, b3;
    
    uart_send(CMD_GET_RESULT);
    
    b0 = uart_recv();  // LSB
    b1 = uart_recv();
    b2 = uart_recv();
    b3 = uart_recv();  // MSB
    
    return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0;
}

//=============================================================================
// 主程序
//=============================================================================
int main(void) {
    u32 result;
    
    // 示例程序: 计算 100 + 200 = 300
    // 结果存入 x12
    u32 program[] = {
        0x06400513,  // addi x10, x0, 100
        0x0C800593,  // addi x11, x0, 200
        0x00B50633,  // add  x12, x10, x11
        0x00000013   // nop (结束标记)
    };
    
    printf("=== PS 发送机器码给 RISC-V ===\n\n");
    
    // 初始化 UART
    XUartLite_Initialize(&UartLite, XPAR_AXI_UARTLITE_0_DEVICE_ID);
    
    // 等待 RISC-V 就绪 ("RV\n")
    printf("[1] 等待 RISC-V 就绪...\n");
    while (uart_recv() != 'R');
    uart_recv();  // 'V'
    uart_recv();  // '\n'
    printf("    OK\n");
    
    // 发送程序
    printf("[2] 发送机器码 (%d 字节)...\n", sizeof(program));
    if (load_program(program, 4) == 0) {
        printf("    OK\n");
    } else {
        printf("    FAILED\n");
        return -1;
    }
    
    // 执行
    printf("[3] 执行...\n");
    if (run_program() == 0) {
        printf("    OK\n");
    } else {
        printf("    FAILED\n");
        return -1;
    }
    
    // 获取结果
    printf("[4] 获取结果...\n");
    result = get_result();
    printf("    x12 = %u\n", result);
    
    // 验证
    printf("\n结果: 100 + 200 = %u %s\n", result, 
           (result == 300) ? "[正确]" : "[错误]");
    
    return 0;
}
