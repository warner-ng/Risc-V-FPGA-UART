// riscv_dynamic_tb.v
// 测试平台：验证动态加载的 RISC-V 能正确执行指令
// 使用 Icarus Verilog 仿真

`timescale 1ns / 1ps

module riscv_dynamic_tb;

    // 时钟和复位
    reg clk;
    reg reset_n;  // active low
    
    // UART 信号
    wire uart_tx;
    reg uart_rx;
    
    // LED
    wire [1:0] led;
    
    // 时钟生成 (100MHz -> 10ns 周期)
    initial clk = 0;
    always #5 clk = ~clk;
    
    // 实例化 DUT
    fpga_top_dynamic dut (
        .sys_clk(clk),
        .key(reset_n),
        .led(led),
        .uart_tx(uart_tx),
        .uart_rx(uart_rx)
    );

    // UART 参数 (使用与 DUT 相同的波特率分频值)
    // 注意: 仿真中使用较小的值加速仿真
    parameter BAUD_DIV = 10;  // 加速仿真 (实际硬件是 868)
    
    // 接收缓冲
    reg [7:0] rx_buffer [0:15];
    integer rx_count;
    
    //=========================================================================
    // UART 发送任务 (模拟 PS 发送给 RISC-V)
    //=========================================================================
    task uart_send_byte;
        input [7:0] data;
        integer i;
        begin
            $display("[%0t] TX -> RISC-V: 0x%02X", $time, data);
            
            // Start bit
            uart_rx = 1'b0;
            repeat(BAUD_DIV) @(posedge clk);
            
            // Data bits (LSB first)
            for (i = 0; i < 8; i = i + 1) begin
                uart_rx = data[i];
                repeat(BAUD_DIV) @(posedge clk);
            end
            
            // Stop bit
            uart_rx = 1'b1;
            repeat(BAUD_DIV) @(posedge clk);
            
            // 间隔
            repeat(BAUD_DIV/2) @(posedge clk);
        end
    endtask
    
    //=========================================================================
    // UART 接收任务 (接收 RISC-V 发送的数据)
    //=========================================================================
    task uart_recv_byte;
        output [7:0] data;
        integer i;
        begin
            // 等待 start bit
            wait(uart_tx == 1'b0);
            
            // 等到 start bit 中间
            repeat(BAUD_DIV/2) @(posedge clk);
            
            // 采样 8 个数据位
            for (i = 0; i < 8; i = i + 1) begin
                repeat(BAUD_DIV) @(posedge clk);
                data[i] = uart_tx;
            end
            
            // 等待 stop bit
            repeat(BAUD_DIV) @(posedge clk);
            
            $display("[%0t] RX <- RISC-V: 0x%02X ('%c')", $time, data, 
                     (data >= 32 && data < 127) ? data : 8'h2E);
        end
    endtask

    //=========================================================================
    // 测试程序
    //=========================================================================
    reg [7:0] recv_data;
    reg [31:0] result;
    
    initial begin
        // 生成波形文件
        $dumpfile("riscv_dynamic_test.vcd");
        $dumpvars(0, riscv_dynamic_tb);
        
        // 初始化
        reset_n = 0;
        uart_rx = 1'b1;  // UART idle high
        rx_count = 0;
        
        $display("");
        $display("========================================");
        $display("  RISC-V Dynamic Load Simulation Test");
        $display("========================================");
        $display("");
        
        // 复位
        repeat(100) @(posedge clk);
        reset_n = 1;  // Release reset
        $display("[%0t] Reset released", $time);
        
        // Wait for RISC-V startup message "RV\n"
        $display("");
        $display("--- Waiting for RISC-V startup ---");
        uart_recv_byte(recv_data);  // 'R'
        uart_recv_byte(recv_data);  // 'V'
        uart_recv_byte(recv_data);  // '\n'
        $display("RISC-V is ready!");
        
        // Send LOAD_CODE command
        $display("");
        $display("--- Sending machine code (4 instructions) ---");
        uart_send_byte(8'h10);      // CMD_LOAD_CODE
        uart_send_byte(8'h10);      // Length low byte = 16
        uart_send_byte(8'h00);      // Length high byte = 0
        
        // Instruction 1: addi x10, x0, 100 = 0x06400513
        $display("  Instr 1: addi x10, x0, 100  ->  0x06400513");
        uart_send_byte(8'h13);  // Byte 0 (LSB)
        uart_send_byte(8'h05);  // Byte 1
        uart_send_byte(8'h40);  // Byte 2
        uart_send_byte(8'h06);  // Byte 3 (MSB)
        
        // Instruction 2: addi x11, x0, 200 = 0x0C800593
        $display("  Instr 2: addi x11, x0, 200  ->  0x0C800593");
        uart_send_byte(8'h93);  // Byte 0 (LSB)
        uart_send_byte(8'h05);  // Byte 1
        uart_send_byte(8'h80);  // Byte 2
        uart_send_byte(8'h0C);  // Byte 3 (MSB)
        
        // Instruction 3: add x12, x10, x11 = 0x00B50633
        $display("  Instr 3: add  x12, x10, x11  ->  0x00B50633");
        uart_send_byte(8'h33);  // Byte 0 (LSB)
        uart_send_byte(8'h06);  // Byte 1
        uart_send_byte(8'hB5);  // Byte 2
        uart_send_byte(8'h00);  // Byte 3 (MSB)
        
        // Instruction 4: nop = 0x00000013
        $display("  Instr 4: nop (end marker)  ->  0x00000013");
        uart_send_byte(8'h13);  // Byte 0 (LSB)
        uart_send_byte(8'h00);  // Byte 1
        uart_send_byte(8'h00);  // Byte 2
        uart_send_byte(8'h00);  // Byte 3 (MSB)
        
        // Wait for ACK
        uart_recv_byte(recv_data);
        if (recv_data == 8'h06) begin
            $display("Received ACK - Load success!");
        end else begin
            $display("ERROR: Expected ACK(0x06), got 0x%02X", recv_data);
        end
        
        // Send RUN command
        $display("");
        $display("--- Executing program ---");
        uart_send_byte(8'h20);      // CMD_RUN
        
        // Wait for DONE
        uart_recv_byte(recv_data);
        if (recv_data == 8'h0F) begin
            $display("Received DONE - Execution complete!");
        end else begin
            $display("ERROR: Expected DONE(0x0F), got 0x%02X", recv_data);
        end
        
        // Send GET_RESULT command
        $display("");
        $display("--- Getting result ---");
        uart_send_byte(8'h30);      // CMD_GET_RESULT
        
        // 接收 4 字节结果 (小端序)
        uart_recv_byte(recv_data);
        result[7:0] = recv_data;
        
        uart_recv_byte(recv_data);
        result[15:8] = recv_data;
        
        uart_recv_byte(recv_data);
        result[23:16] = recv_data;
        
        uart_recv_byte(recv_data);
        result[31:24] = recv_data;
        
        // Display result
        $display("");
        $display("========================================");
        $display("  TEST RESULT");
        $display("========================================");
        $display("  x12 = %0d (0x%08X)", result, result);
        $display("  Expected: 300 (100 + 200)");
        $display("");
        
        if (result == 32'd300) begin
            $display("  *** TEST PASSED! ***");
        end else begin
            $display("  *** TEST FAILED! ***");
        end
        
        $display("========================================");
        $display("");
        
        // 额外等待
        repeat(1000) @(posedge clk);
        
        $finish;
    end
    
    // Timeout protection
    initial begin
        #100000000;  // 100ms timeout
        $display("ERROR: Simulation timeout!");
        $finish;
    end
    
    // Debug: Monitor CPU execution during RUN state
    always @(posedge clk) begin
        if (dut.cpu_run && !dut.cpu.done) begin
            // 详细显示寄存器和前送状态
            if (dut.cpu.rvsingle.dp.run) begin
                $display("[CPU@%0t] PC=0x%08h Instr=0x%08h | x10=%0d x11=%0d x12=%0d", 
                         $time, dut.cpu.PC, dut.cpu.Instr,
                         dut.cpu.rvsingle.dp.rf.rf[10],
                         dut.cpu.rvsingle.dp.rf.rf[11],
                         dut.cpu.rvsingle.dp.rf.rf[12]);
            end
        end
    end
    
    // 监控指令内存写入
    always @(posedge clk) begin
        if (dut.imem_we) begin
            $display("[IMEM_WR@%0t] Addr=0x%02h Data=0x%08h", $time, dut.imem_waddr, dut.imem_wdata);
        end
    end
    
    // 监控状态机转换
    reg [3:0] prev_state;
    initial prev_state = 4'hF;
    
    always @(posedge clk) begin
        if (dut.state != prev_state) begin
            prev_state <= dut.state;
            case (dut.state)
                4'd0: $display("[STATE@%0t] -> INIT", $time);
                4'd1: $display("[STATE@%0t] -> IDLE", $time);
                4'd2: $display("[STATE@%0t] -> LOAD_LEN", $time);
                4'd3: $display("[STATE@%0t] -> LOAD_CODE", $time);
                4'd4: $display("[STATE@%0t] -> RUN (执行开始)", $time);
                4'd5: $display("[STATE@%0t] -> SEND_DONE", $time);
                4'd6: $display("[STATE@%0t] -> GET_RESULT", $time);
            endcase
        end
    end

endmodule
