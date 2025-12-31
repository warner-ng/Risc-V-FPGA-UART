// riscvsingle_dynamic_load.v
// 支持动态加载机器码的完整 RISC-V 处理器
// 基于 riscvsingle_fpga_forwarding.v，添加 UART 动态加载功能
// PS 通过 UART 发送机器码，RISC-V 加载执行并返回结果
// 顶层模块: fpga_top_dynamic

module fpga_top_dynamic (
    input wire sys_clk,
    input wire key,
    output wire [1:0] led,
    
    // UART signals for PS communication
    output wire uart_tx,           // RISC-V TX -> PS RX
    input wire uart_rx             // RISC-V RX <- PS TX
);
    wire reset = ~key;
    
    // 状态机状态
    localparam STATE_INIT       = 4'd0;   // 发送启动消息
    localparam STATE_IDLE       = 4'd1;   // 等待命令
    localparam STATE_LOAD_LEN   = 4'd2;   // 接收代码长度
    localparam STATE_LOAD_CODE  = 4'd3;   // 接收机器码
    localparam STATE_RUN        = 4'd4;   // 执行代码
    localparam STATE_SEND_DONE  = 4'd5;   // 发送完成信号
    localparam STATE_GET_RESULT = 4'd6;   // 发送结果
    
    // 命令定义
    localparam CMD_LOAD_CODE  = 8'h10;
    localparam CMD_RUN        = 8'h20;
    localparam CMD_GET_RESULT = 8'h30;
    localparam ACK            = 8'h06;
    localparam DONE           = 8'h0F;
    
    reg [3:0] state;
    reg [15:0] code_length;       // 代码长度（字节）
    reg [15:0] bytes_received;    // 已接收字节数
    reg [5:0] instr_addr;         // 指令写入地址
    reg [31:0] instr_buffer;      // 指令缓冲
    reg [1:0] byte_index;         // 字节索引 (0-3)
    reg [2:0] init_step;          // 初始化步骤
    
    // CPU 控制
    reg cpu_run;                  // CPU 运行使能
    reg cpu_reset;                // CPU 复位
    wire cpu_done;                // CPU 执行完成 (遇到NOP)
    
    // 指令内存写入接口
    reg imem_we;
    reg [5:0] imem_waddr;
    reg [31:0] imem_wdata;
    
    // UART 接口
    reg [7:0] tx_data;
    reg tx_start;
    wire tx_busy;
    wire [7:0] rx_data;
    wire rx_ready;
    
    // CPU 接口
    wire [31:0] cpu_pc;
    wire [31:0] cpu_instr;
    wire [31:0] result_reg;       // x12 寄存器的值作为结果
    wire cpu_mem_write;
    wire cpu_pcsrc;
    
    // 结果发送状态
    reg [1:0] result_byte_idx;
    
    // LED 显示状态
    assign led[0] = ~cpu_run;
    assign led[1] = ~cpu_pcsrc;

    //=========================================================================
    // 主状态机
    //=========================================================================
    always @(posedge sys_clk or posedge reset) begin
        if (reset) begin
            state <= STATE_INIT;
            code_length <= 16'b0;
            bytes_received <= 16'b0;
            instr_addr <= 6'b0;
            instr_buffer <= 32'b0;
            byte_index <= 2'b0;
            init_step <= 3'b0;
            cpu_run <= 1'b0;
            cpu_reset <= 1'b1;
            imem_we <= 1'b0;
            tx_data <= 8'b0;
            tx_start <= 1'b0;
            result_byte_idx <= 2'b0;
        end else begin
            // 默认值
            tx_start <= 1'b0;
            imem_we <= 1'b0;
            
            case (state)
                //-------------------------------------------------------------
                // STATE_INIT: 发送启动消息 "RV\n"
                //-------------------------------------------------------------
                STATE_INIT: begin
                    cpu_reset <= 1'b1;
                    if (!tx_busy && !tx_start) begin
                        case (init_step)
                            3'd0: begin tx_data <= 8'h52; tx_start <= 1'b1; init_step <= 3'd1; end  // 'R'
                            3'd1: begin tx_data <= 8'h56; tx_start <= 1'b1; init_step <= 3'd2; end  // 'V'
                            3'd2: begin tx_data <= 8'h0A; tx_start <= 1'b1; init_step <= 3'd3; end  // '\n'
                            3'd3: begin state <= STATE_IDLE; end
                            default: init_step <= 3'd0;
                        endcase
                    end
                end
                
                //-------------------------------------------------------------
                // STATE_IDLE: 等待命令
                //-------------------------------------------------------------
                STATE_IDLE: begin
                    cpu_run <= 1'b0;
                    // 注意: 不要在这里复位 CPU，否则会清除结果寄存器
                    if (rx_ready) begin
                        case (rx_data)
                            CMD_LOAD_CODE: begin
                                state <= STATE_LOAD_LEN;
                                bytes_received <= 16'b0;
                                instr_addr <= 6'b0;
                                byte_index <= 2'b0;
                                cpu_reset <= 1'b1;  // 加载新代码前复位 CPU
                            end
                            CMD_RUN: begin
                                state <= STATE_RUN;
                                cpu_reset <= 1'b0;  // 释放 CPU 复位
                                cpu_run <= 1'b1;
                            end
                            CMD_GET_RESULT: begin
                                state <= STATE_GET_RESULT;
                                result_byte_idx <= 2'b0;
                            end
                        endcase
                    end
                end
                
                //-------------------------------------------------------------
                // STATE_LOAD_LEN: 接收代码长度 (2字节, 小端)
                //-------------------------------------------------------------
                STATE_LOAD_LEN: begin
                    if (rx_ready) begin
                        if (bytes_received == 0) begin
                            code_length[7:0] <= rx_data;
                            bytes_received <= 16'd1;
                        end else begin
                            code_length[15:8] <= rx_data;
                            bytes_received <= 16'd0;
                            state <= STATE_LOAD_CODE;
                        end
                    end
                end
                
                //-------------------------------------------------------------
                // STATE_LOAD_CODE: 接收机器码
                //-------------------------------------------------------------
                STATE_LOAD_CODE: begin
                    if (rx_ready) begin
                        // 将字节放入缓冲区 (小端序)
                        case (byte_index)
                            2'd0: instr_buffer[7:0]   <= rx_data;
                            2'd1: instr_buffer[15:8]  <= rx_data;
                            2'd2: instr_buffer[23:16] <= rx_data;
                            2'd3: instr_buffer[31:24] <= rx_data;
                        endcase
                        
                        bytes_received <= bytes_received + 1;
                        
                        if (byte_index == 2'd3) begin
                            // 一条完整指令，写入指令内存
                            byte_index <= 2'd0;
                            imem_we <= 1'b1;
                            imem_waddr <= instr_addr;
                            imem_wdata <= {rx_data, instr_buffer[23:0]};
                            instr_addr <= instr_addr + 1;
                        end else begin
                            byte_index <= byte_index + 1;
                        end
                        
                        // 检查是否接收完毕
                        if (bytes_received + 1 >= code_length) begin
                            state <= STATE_SEND_DONE;
                            tx_data <= ACK;
                            tx_start <= 1'b1;
                        end
                    end
                end
                
                //-------------------------------------------------------------
                // STATE_SEND_DONE: 发送 ACK/DONE
                //-------------------------------------------------------------
                STATE_SEND_DONE: begin
                    if (!tx_busy && !tx_start) begin
                        state <= STATE_IDLE;
                    end
                end
                
                //-------------------------------------------------------------
                // STATE_RUN: 执行代码
                //-------------------------------------------------------------
                STATE_RUN: begin
                    cpu_reset <= 1'b0;
                    // 检测执行完成 (遇到 NOP 或执行超过加载的指令数)
                    if (cpu_done || (cpu_pc >= {instr_addr, 2'b00})) begin
                        cpu_run <= 1'b0;
                        tx_data <= DONE;
                        tx_start <= 1'b1;
                        state <= STATE_SEND_DONE;
                    end
                end
                
                //-------------------------------------------------------------
                // STATE_GET_RESULT: 发送结果 (4字节, 小端)
                //-------------------------------------------------------------
                STATE_GET_RESULT: begin
                    if (!tx_busy && !tx_start) begin
                        case (result_byte_idx)
                            2'd0: begin tx_data <= result_reg[7:0];   tx_start <= 1'b1; result_byte_idx <= 2'd1; end
                            2'd1: begin tx_data <= result_reg[15:8];  tx_start <= 1'b1; result_byte_idx <= 2'd2; end
                            2'd2: begin tx_data <= result_reg[23:16]; tx_start <= 1'b1; result_byte_idx <= 2'd3; end
                            2'd3: begin tx_data <= result_reg[31:24]; tx_start <= 1'b1; state <= STATE_IDLE; end
                        endcase
                    end
                end
                
                default: state <= STATE_IDLE;
            endcase
        end
    end

    //=========================================================================
    // UART 收发器
    //=========================================================================
    uart_tx_simple uart_tx_inst (
        .clk(sys_clk),
        .reset(reset),
        .data(tx_data),
        .start(tx_start),
        .tx(uart_tx),
        .busy(tx_busy)
    );
    
    uart_rx_simple uart_rx_inst (
        .clk(sys_clk),
        .reset(reset),
        .rx(uart_rx),
        .data(rx_data),
        .ready(rx_ready)
    );

    //=========================================================================
    // 完整 RISC-V CPU 核心 (带数据前送、分支、load/store)
    //=========================================================================
    top_dynamic cpu (
        .clk(sys_clk),
        .reset(cpu_reset),
        .run(cpu_run),
        .PC(cpu_pc),
        .Instr(cpu_instr),
        .MemWrite(cpu_mem_write),
        .PCSrc(cpu_pcsrc),
        .result_x12(result_reg),
        .done(cpu_done),
        // 指令内存写入接口
        .imem_we(imem_we),
        .imem_waddr(imem_waddr),
        .imem_wdata(imem_wdata)
    );

endmodule

//=============================================================================
// 简单 UART 发送器
//=============================================================================
module uart_tx_simple (
    input wire clk,
    input wire reset,
    input wire [7:0] data,
    input wire start,
    output reg tx,
    output reg busy
);
    // 波特率: 115200 @ 50MHz -> 434 cycles per bit
    // 仿真时使用 -DSIM_FAST 加速
    `ifdef SIM_FAST
    parameter BAUD_DIV = 10;
    `else
    parameter BAUD_DIV = 434;
    `endif
    
    reg [15:0] baud_cnt;
    reg [3:0] bit_idx;
    reg [9:0] shift_reg;
    
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            tx <= 1'b1;
            busy <= 1'b0;
            baud_cnt <= 0;
            bit_idx <= 0;
            shift_reg <= 10'h3FF;
        end else begin
            if (!busy) begin
                tx <= 1'b1;
                if (start) begin
                    busy <= 1'b1;
                    shift_reg <= {1'b1, data, 1'b0};
                    bit_idx <= 0;
                    baud_cnt <= 0;
                end
            end else begin
                if (baud_cnt == BAUD_DIV - 1) begin
                    baud_cnt <= 0;
                    tx <= shift_reg[0];
                    shift_reg <= {1'b1, shift_reg[9:1]};
                    if (bit_idx == 9) begin
                        busy <= 1'b0;
                    end else begin
                        bit_idx <= bit_idx + 1;
                    end
                end else begin
                    baud_cnt <= baud_cnt + 1;
                end
            end
        end
    end
endmodule

//=============================================================================
// 简单 UART 接收器
//=============================================================================
module uart_rx_simple (
    input wire clk,
    input wire reset,
    input wire rx,
    output reg [7:0] data,
    output reg ready
);
    // 波特率: 115200 @ 50MHz -> 434 cycles per bit
    `ifdef SIM_FAST
    parameter BAUD_DIV = 10;
    `else
    parameter BAUD_DIV = 434;
    `endif
    
    // 同步器 (减少到2级，加快响应)
    reg [1:0] rx_sync;
    wire rx_in = rx_sync[1];
    
    reg [15:0] baud_cnt;
    reg [3:0] bit_idx;
    reg [7:0] shift_reg;
    reg receiving;
    
    always @(posedge clk or posedge reset) begin
        if (reset)
            rx_sync <= 2'b11;
        else
            rx_sync <= {rx_sync[0], rx};
    end
    
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            data <= 0;
            ready <= 0;
            baud_cnt <= 0;
            bit_idx <= 0;
            shift_reg <= 0;
            receiving <= 0;
        end else begin
            ready <= 0;
            
            if (!receiving) begin
                if (rx_in == 0) begin  // 检测到起始位
                    receiving <= 1;
                    baud_cnt <= 0;
                    bit_idx <= 0;
                end
            end else begin
                baud_cnt <= baud_cnt + 1;
                
                // 在每个 bit 的中间采样
                if (bit_idx == 0 && baud_cnt == BAUD_DIV/2 - 1) begin
                    // 起始位中间，准备采样数据位
                    baud_cnt <= 0;
                    bit_idx <= 1;
                end else if (bit_idx >= 1 && bit_idx <= 8 && baud_cnt == BAUD_DIV - 1) begin
                    // 采样数据位
                    shift_reg <= {rx_in, shift_reg[7:1]};
                    baud_cnt <= 0;
                    bit_idx <= bit_idx + 1;
                end else if (bit_idx == 9 && baud_cnt == BAUD_DIV - 1) begin
                    // 停止位
                    if (rx_in == 1) begin
                        data <= shift_reg;
                        ready <= 1;
                    end
                    receiving <= 0;
                    baud_cnt <= 0;
                    bit_idx <= 0;
                end
            end
        end
    end
endmodule

//=============================================================================
// Top 模块 (支持动态加载)
//=============================================================================
module top_dynamic (
    input wire clk,
    input wire reset,
    input wire run,
    output wire [31:0] PC,
    output wire [31:0] Instr,
    output wire MemWrite,
    output wire PCSrc,
    output wire [31:0] result_x12,
    output wire done,
    // 指令内存写入接口
    input wire imem_we,
    input wire [5:0] imem_waddr,
    input wire [31:0] imem_wdata
);
    wire [31:0] WriteData;
    wire [31:0] DataAdr;
    wire [31:0] ReadData;
    wire [3:0] ByteEnable;

    riscvsingle_dynamic rvsingle(
        .clk(clk),
        .reset(reset),
        .run(run),
        .PC(PC),
        .Instr(Instr),
        .MemWrite(MemWrite),
        .ALUResult(DataAdr),
        .WriteData(WriteData),
        .ReadData(ReadData),
        .ByteEnable(ByteEnable),
        .PCSrc(PCSrc),
        .result_x12(result_x12),
        .done(done)
    );
    
    imem_dynamic imem(
        .clk(clk),
        .a(PC),
        .rd(Instr),
        .we(imem_we),
        .waddr(imem_waddr),
        .wdata(imem_wdata)
    );
    
    dmem dmem(
        .clk(clk),
        .we(MemWrite & run),
        .a(DataAdr),
        .wd(WriteData),
        .rd(ReadData),
        .be(ByteEnable)
    );
endmodule

//=============================================================================
// RISC-V 单周期处理器 (带数据前送)
//=============================================================================
module riscvsingle_dynamic (
    input wire clk,
    input wire reset,
    input wire run,
    output wire [31:0] PC,
    input wire [31:0] Instr,
    output wire MemWrite,
    output wire [31:0] ALUResult,
    output wire [31:0] WriteData,
    input wire [31:0] ReadData,
    output wire [3:0] ByteEnable,
    output wire PCSrc,
    output wire [31:0] result_x12,
    output reg done
);
    wire ALUSrc, RegWrite, Jump, Zero, JALR, SrcASel;
    wire [1:0] ResultSrc;
    wire [2:0] ImmSrc;
    wire [3:0] ALUControl;

    wire [31:0] ALUResult_internal; 
    assign ALUResult = ALUResult_internal;
    
    // 检测 NOP 指令 (addi x0, x0, 0 = 0x00000013)
    wire is_nop = (Instr == 32'h00000013) || (Instr == 32'h00000000);
    
    always @(posedge clk or posedge reset) begin
        if (reset)
            done <= 1'b0;
        else if (run && is_nop)
            done <= 1'b1;
    end
    
    controller c(
        .op(Instr[6:0]), .funct3(Instr[14:12]), .funct7b5(Instr[30]),
        .Zero(Zero), .ALUResult(ALUResult_internal), .ResultSrc(ResultSrc), 
        .MemWrite(MemWrite), .PCSrc(PCSrc), .ALUSrc(ALUSrc), .RegWrite(RegWrite),
        .Jump(Jump), .ImmSrc(ImmSrc), .ALUControl(ALUControl), .JALR(JALR), .SrcASel(SrcASel)
    );

    datapath_dynamic dp(
        .clk(clk), .reset(reset), .run(run), .ResultSrc(ResultSrc), .PCSrc(PCSrc),
        .ALUSrc(ALUSrc), .RegWrite(RegWrite), .ImmSrc(ImmSrc), .ALUControl(ALUControl),
        .JALR(JALR), .SrcASel(SrcASel), .Zero(Zero), .PC(PC), .Instr(Instr),
        .ALUResult(ALUResult_internal), .WriteData(WriteData), .ReadData(ReadData), 
        .ByteEnable(ByteEnable), .result_x12(result_x12)
    );
endmodule

//=============================================================================
// 控制器
//=============================================================================
module controller (
    input wire [6:0] op,
    input wire [2:0] funct3,
    input wire funct7b5,
    input wire Zero,
    input wire [31:0] ALUResult,
    output wire [1:0] ResultSrc,
    output wire MemWrite,
    output wire PCSrc,
    output wire ALUSrc,
    output wire RegWrite,
    output wire Jump,
    output wire [2:0] ImmSrc,
    output wire [3:0] ALUControl,
    output wire JALR,
    output wire SrcASel
);
    wire [1:0] ALUOp;
    wire Branch;

    maindec md(
        .op(op),
        .ResultSrc(ResultSrc),
        .MemWrite(MemWrite),
        .Branch(Branch),
        .ALUSrc(ALUSrc),
        .RegWrite(RegWrite),
        .Jump(Jump),
        .ImmSrc(ImmSrc),
        .ALUOp(ALUOp),
        .JALR(JALR),
        .SrcASel(SrcASel)
    );
    
    aludec ad(
        .opb5(op[5]),
        .funct3(funct3),
        .funct7b5(funct7b5),
        .ALUOp(ALUOp),
        .ALUControl(ALUControl)
    );

    wire take_branch;
    wire alu_result_is_one = |ALUResult;

    assign take_branch = (Branch & (
                          ((funct3 == 3'b000) & Zero) |
                          ((funct3 == 3'b001) & ~Zero) |
                          ((funct3 == 3'b100) & alu_result_is_one) |
                          ((funct3 == 3'b101) & ~alu_result_is_one) |
                          ((funct3 == 3'b110) & alu_result_is_one) |
                          ((funct3 == 3'b111) & ~alu_result_is_one)
                         ));

    assign PCSrc = take_branch | Jump;
endmodule

//=============================================================================
// 主译码器
//=============================================================================
module maindec (
    input wire [6:0] op,
    output wire [1:0] ResultSrc,
    output wire MemWrite,
    output wire Branch,
    output wire ALUSrc,
    output wire RegWrite,
    output wire Jump,
    output wire [2:0] ImmSrc,
    output wire [1:0] ALUOp,
    output wire JALR,
    output wire SrcASel
);
    reg [14:0] controls;
    assign {SrcASel, JALR, RegWrite, ImmSrc, ALUSrc, MemWrite, ResultSrc, Branch, ALUOp, Jump} = controls;

    always @(*) begin
        case (op)
            7'b0000011: controls = 15'b0_0_1_000_1_0_01_0_00_0; // lw/lb/lh/lbu/lhu
            7'b0100011: controls = 15'b0_0_0_001_1_1_xx_0_00_0; // sw/sb/sh
            7'b0110011: controls = 15'b0_0_1_xxx_0_0_00_0_10_0; // R-type
            7'b1100011: controls = 15'b0_0_0_010_0_0_00_1_01_0; // B-type
            7'b0010011: controls = 15'b0_0_1_000_1_0_00_0_10_0; // I-type ALU
            7'b0110111: controls = 15'b0_0_1_100_0_0_11_0_00_0; // LUI
            7'b0010111: controls = 15'b1_0_1_100_1_0_00_0_00_0; // AUIPC
            7'b1101111: controls = 15'b0_0_1_011_0_0_10_0_00_1; // JAL
            7'b1100111: controls = 15'b0_1_1_000_1_0_10_0_00_1; // JALR
            default:    controls = 15'b0_0_0_000_0_0_00_0_00_0; // NOP/unknown
        endcase
    end
endmodule

//=============================================================================
// ALU 译码器
//=============================================================================
module aludec (
    input wire opb5,
    input wire [2:0] funct3,
    input wire funct7b5,
    input wire [1:0] ALUOp,
    output reg [3:0] ALUControl
);
    wire is_rtype = opb5;
    wire is_shift = (funct3 == 3'b001) | (funct3 == 3'b101);
    wire use_sub_or_shift_arith = funct7b5 & (is_rtype | is_shift);

    always @(*) begin
        case (ALUOp)
            2'b00: ALUControl = 4'b0000; // lw, sw -> ADD
            2'b01:
                case(funct3)
                    3'b000, 3'b001: ALUControl = 4'b0001; // BEQ, BNE -> SUB
                    3'b100, 3'b101: ALUControl = 4'b1000; // BLT, BGE -> SLT
                    3'b110, 3'b111: ALUControl = 4'b1001; // BLTU, BGEU -> SLTU
                    default: ALUControl = 4'b0000;
                endcase
            2'b10:
                case (funct3)
                    3'b000:
                        if (use_sub_or_shift_arith) ALUControl = 4'b0001; // SUB
                        else                        ALUControl = 4'b0000; // ADD
                    3'b001: ALUControl = 4'b0101; // SLL/SLLI
                    3'b010: ALUControl = 4'b1000; // SLT/SLTI
                    3'b011: ALUControl = 4'b1001; // SLTU/SLTIU
                    3'b100: ALUControl = 4'b0100; // XOR/XORI
                    3'b101:
                        if (use_sub_or_shift_arith) ALUControl = 4'b0111; // SRA
                        else                        ALUControl = 4'b0110; // SRL
                    3'b110: ALUControl = 4'b0011; // OR/ORI
                    3'b111: ALUControl = 4'b0010; // AND/ANDI
                    default: ALUControl = 4'b0000;
                endcase
            default: ALUControl = 4'b0000;
        endcase
    end
endmodule

//=============================================================================
// 数据通路 (带数据前送)
//=============================================================================
module datapath_dynamic (
    input wire clk,
    input wire reset,
    input wire run,
    input wire [1:0] ResultSrc,
    input wire PCSrc,
    input wire ALUSrc,
    input wire RegWrite,
    input wire [2:0] ImmSrc,
    input wire [3:0] ALUControl,
    input wire JALR,
    input wire SrcASel,
    output wire Zero,
    output wire [31:0] PC,
    input wire [31:0] Instr,
    output wire [31:0] ALUResult,
    output wire [31:0] WriteData,
    input wire [31:0] ReadData,
    output wire [3:0] ByteEnable,
    output wire [31:0] result_x12
);
    wire [31:0] PCNext;
    wire [31:0] PCPlus4;
    wire [31:0] PCTarget;
    wire [31:0] ImmExt;
    wire [31:0] SrcB;
    wire [31:0] Result;
    wire [31:0] JumpTarget; 
    wire [31:0] WriteData_raw;
    wire [31:0] SrcA_pre_mux;
    wire [31:0] SrcA;
    wire [31:0] LoadData;

    // --- Forwarding related signals ---
    reg [4:0] rd_prev;
    reg regwrite_prev;
    reg [31:0] result_prev;
    wire [1:0] forward_a;
    wire [1:0] forward_b;
    wire [31:0] SrcA_forwarded;
    wire [31:0] SrcB_forwarded;

    // Forwarding unit
    forwarding_unit fwd_unit(
        .rs1_current(Instr[19:15]),
        .rs2_current(Instr[24:20]),
        .rd_prev(rd_prev),
        .regwrite_prev(regwrite_prev),
        .forward_a(forward_a),
        .forward_b(forward_b)
    );

    // Save previous instruction info at posedge
    // NOTE: rd_prev and result_prev should be from the PREVIOUS clock cycle
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            rd_prev <= 5'b0;
            regwrite_prev <= 1'b0;
            result_prev <= 32'b0;
        end else if (run) begin
            rd_prev <= Instr[11:7];  // Current instruction's rd (will be prev next cycle)
            regwrite_prev <= RegWrite;
            result_prev <= Result;
        end
    end

    // Forward muxes (3-way)
    mux3 #(.WIDTH(32)) forward_a_mux(
        .d0(SrcA_pre_mux),
        .d1(result_prev),
        .d2(32'b0),
        .s(forward_a),
        .y(SrcA_forwarded)
    );

    mux3 #(.WIDTH(32)) forward_b_mux(
        .d0(WriteData_raw),
        .d1(result_prev),
        .d2(32'b0),
        .s(forward_b),
        .y(SrcB_forwarded)
    );

    // Mux to select SrcA for AUIPC
    mux2 #(.WIDTH(32)) srcamux (
        .d0(SrcA_forwarded),
        .d1(PC),
        .s(SrcASel),
        .y(SrcA)
    );

    // PC register with run enable
    flopr_en #(.WIDTH(32)) pcreg(
        .clk(clk),
        .reset(reset),
        .en(run),
        .d(PCNext),
        .q(PC)
    );
    
    adder pcadd4(
        .a(PC),
        .b(32'd4),
        .y(PCPlus4)
    );
    
    adder pcaddbranch(
        .a(PC),
        .b(ImmExt),
        .y(PCTarget)
    );

    // Mux for JALR
    mux2 #(.WIDTH(32)) jump_target_mux(
        .d0(PCTarget),
        .d1(ALUResult),
        .s(JALR),
        .y(JumpTarget)
    );

    mux2 #(.WIDTH(32)) pcmux(
        .d0(PCPlus4),
        .d1(JumpTarget),
        .s(PCSrc),
        .y(PCNext)
    );
  
    regfile_dynamic rf(
        .clk(clk),
        .reset(reset),
        .run(run),
        .we3(RegWrite),
        .a1(Instr[19:15]),
        .a2(Instr[24:20]),
        .a3(Instr[11:7]),
        .wd3(Result),
        .rd1(SrcA_pre_mux),
        .rd2(WriteData_raw),
        .result_x12(result_x12)
    );
    
    extend ext(
        .instruction(Instr),
        .immsrc(ImmSrc),
        .immext(ImmExt)
    );
    
    mux2 #(.WIDTH(32)) srcbmux(
        .d0(SrcB_forwarded),
        .d1(ImmExt),
        .s(ALUSrc),
        .y(SrcB)
    );
    
    alu alu_inst(
        .a(SrcA),
        .b(SrcB),
        .alucontrol(ALUControl),
        .result(ALUResult),
        .zero(Zero)
    );

    // Load data processing
    wire [2:0] load_funct3 = Instr[14:12];
    wire [1:0] addr_lsb = ALUResult[1:0];
    reg [31:0] load_data_extended;

    always@(*) begin
        load_data_extended = ReadData; 
        case (load_funct3)
            3'b000: // LB
                case (addr_lsb)
                    2'b00: load_data_extended = {{24{ReadData[7]}}, ReadData[7:0]};
                    2'b01: load_data_extended = {{24{ReadData[15]}}, ReadData[15:8]};
                    2'b10: load_data_extended = {{24{ReadData[23]}}, ReadData[23:16]};
                    2'b11: load_data_extended = {{24{ReadData[31]}}, ReadData[31:24]};
                endcase
            3'b001: // LH
                case (addr_lsb[1])
                    1'b0: load_data_extended = {{16{ReadData[15]}}, ReadData[15:0]};
                    1'b1: load_data_extended = {{16{ReadData[31]}}, ReadData[31:16]};
                endcase
            3'b100: // LBU
                case (addr_lsb)
                    2'b00: load_data_extended = {24'b0, ReadData[7:0]};
                    2'b01: load_data_extended = {24'b0, ReadData[15:8]};
                    2'b10: load_data_extended = {24'b0, ReadData[23:16]};
                    2'b11: load_data_extended = {24'b0, ReadData[31:24]};
                endcase
            3'b101: // LHU
                case (addr_lsb[1])
                    1'b0: load_data_extended = {16'b0, ReadData[15:0]};
                    1'b1: load_data_extended = {16'b0, ReadData[31:16]};
                endcase
            default: ;
        endcase
    end
    assign LoadData = load_data_extended;

    // Store data alignment
    wire [2:0] store_funct3 = Instr[14:12];
    reg [3:0] be_temp;
    reg [31:0] store_data_aligned;
    
    always@(*) begin
        be_temp = 4'b0000;
        store_data_aligned = WriteData_raw;
        
        case(store_funct3)
            3'b000: // SB
                case (ALUResult[1:0])
                    2'b00: begin be_temp = 4'b0001; store_data_aligned = {24'b0, WriteData_raw[7:0]}; end
                    2'b01: begin be_temp = 4'b0010; store_data_aligned = {16'b0, WriteData_raw[7:0], 8'b0}; end
                    2'b10: begin be_temp = 4'b0100; store_data_aligned = {8'b0, WriteData_raw[7:0], 16'b0}; end
                    2'b11: begin be_temp = 4'b1000; store_data_aligned = {WriteData_raw[7:0], 24'b0}; end
                endcase
            3'b001: // SH
                case (ALUResult[1])
                    1'b0: begin be_temp = 4'b0011; store_data_aligned = {16'b0, WriteData_raw[15:0]}; end
                    1'b1: begin be_temp = 4'b1100; store_data_aligned = {WriteData_raw[15:0], 16'b0}; end
                endcase
            3'b010: begin be_temp = 4'b1111; store_data_aligned = WriteData_raw; end // SW
            default: begin be_temp = 4'b0000; store_data_aligned = WriteData_raw; end
        endcase
    end
    assign ByteEnable = be_temp;
    assign WriteData = store_data_aligned;

    // Result mux (includes LUI path)
    mux4 #(.WIDTH(32)) resultmux(
        .d0(ALUResult),
        .d1(LoadData),
        .d2(PCPlus4),
        .d3(ImmExt),
        .s(ResultSrc),
        .y(Result)
    );
endmodule

//=============================================================================
// 寄存器文件 (输出 x12 作为结果)
//=============================================================================
module regfile_dynamic (
    input wire clk,
    input wire reset,
    input wire run,
    input wire we3,
    input wire [4:0] a1,
    input wire [4:0] a2,
    input wire [4:0] a3,
    input wire [31:0] wd3,
    output wire [31:0] rd1,
    output wire [31:0] rd2,
    output wire [31:0] result_x12
);
    reg [31:0] rf [31:0];
    
    // 输出 x12 作为结果
    assign result_x12 = rf[12];
    
    integer i;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            for (i = 0; i < 32; i = i + 1) begin
                rf[i] <= 32'b0;
            end
        end else if (run) begin
            if (we3 && (a3 != 0))
                rf[a3] <= wd3;
        end
    end
    
    assign rd1 = (a1 != 0) ? rf[a1] : 32'b0;
    assign rd2 = (a2 != 0) ? rf[a2] : 32'b0;
endmodule

//=============================================================================
// 可写入的指令内存
//=============================================================================
module imem_dynamic (
    input wire clk,
    input wire [31:0] a,
    output wire [31:0] rd,
    input wire we,
    input wire [5:0] waddr,
    input wire [31:0] wdata
);
    reg [31:0] RAM [63:0];
    
    integer j;
    initial begin
        for (j = 0; j < 64; j = j + 1) begin
            RAM[j] = 32'h00000013;  // 初始化为 NOP
        end
    end
    
    assign rd = RAM[a[7:2]];
    
    always @(posedge clk) begin
        if (we) begin
            RAM[waddr] <= wdata;
        end
    end
endmodule

//=============================================================================
// 数据内存
//=============================================================================
module dmem (
    input wire clk,
    input wire we,
    input wire [31:0] a,
    input wire [31:0] wd,
    output wire [31:0] rd,
    input wire [3:0] be
);
    reg [31:0] RAM [63:0];
    
    integer j;
    initial begin
        for (j = 0; j < 64; j = j + 1) begin
            RAM[j] = 32'b0;
        end
    end
    
    assign rd = RAM[a[7:2]];
    
    always @(posedge clk) begin
        if (we) begin
            if (be[3]) RAM[a[7:2]][31:24] <= wd[31:24];
            if (be[2]) RAM[a[7:2]][23:16] <= wd[23:16];
            if (be[1]) RAM[a[7:2]][15:8]  <= wd[15:8];
            if (be[0]) RAM[a[7:2]][7:0]   <= wd[7:0];
        end
    end
endmodule

//=============================================================================
// ALU
//=============================================================================
module alu (
    input wire [31:0] a,
    input wire [31:0] b,
    input wire [3:0] alucontrol,
    output reg [31:0] result,
    output wire zero
);
    always @(*) begin
        case (alucontrol)
            4'b0000: result = a + b;           // ADD
            4'b0001: result = a - b;           // SUB
            4'b0010: result = a & b;           // AND
            4'b0011: result = a | b;           // OR
            4'b0100: result = a ^ b;           // XOR
            4'b0101: result = a << b[4:0];     // SLL
            4'b0110: result = a >> b[4:0];     // SRL
            4'b0111: result = $signed(a) >>> b[4:0]; // SRA
            4'b1000: result = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0; // SLT
            4'b1001: result = (a < b) ? 32'd1 : 32'd0; // SLTU
            default: result = 32'b0;
        endcase
    end
    assign zero = (result == 32'b0);
endmodule

//=============================================================================
// 数据前送单元
//=============================================================================
module forwarding_unit (
    input wire [4:0] rs1_current,
    input wire [4:0] rs2_current,
    input wire [4:0] rd_prev,
    input wire regwrite_prev,
    output reg [1:0] forward_a,
    output reg [1:0] forward_b
);
    always @(*) begin
        forward_a = 2'b00;
        forward_b = 2'b00;
        if (regwrite_prev && (rd_prev != 5'b0) && (rd_prev == rs1_current)) begin
            forward_a = 2'b01;
        end
        if (regwrite_prev && (rd_prev != 5'b0) && (rd_prev == rs2_current)) begin
            forward_b = 2'b01;
        end
    end
endmodule

//=============================================================================
// 基本组件
//=============================================================================
module adder (
    input [31:0] a,
    input [31:0] b,
    output wire [31:0] y
);
    assign y = a + b;
endmodule

module extend (
    input wire [31:0] instruction,
    input wire [2:0] immsrc,
    output reg [31:0] immext
);
    always @(*) begin
        case (immsrc)
            3'b000: immext = {{20{instruction[31]}}, instruction[31:20]}; // I-type
            3'b001: immext = {{20{instruction[31]}}, instruction[31:25], instruction[11:7]}; // S-type
            3'b010: immext = {{20{instruction[31]}}, instruction[7], instruction[30:25], instruction[11:8], 1'b0}; // B-type
            3'b011: immext = {{12{instruction[31]}}, instruction[19:12], instruction[20], instruction[30:21], 1'b0}; // J-type
            3'b100: immext = {instruction[31:12], 12'b0}; // U-type
            default: immext = 32'b0;
        endcase
    end
endmodule

module flopr #(parameter WIDTH = 8) (
    input wire clk,
    input wire reset,
    input wire [WIDTH-1:0] d,
    output reg [WIDTH-1:0] q
);
    always @(posedge clk or posedge reset)
        if (reset) q <= 0;
        else q <= d;
endmodule

module flopr_en #(parameter WIDTH = 8) (
    input wire clk,
    input wire reset,
    input wire en,
    input wire [WIDTH-1:0] d,
    output reg [WIDTH-1:0] q
);
    always @(posedge clk or posedge reset)
        if (reset) q <= 0;
        else if (en) q <= d;
endmodule

module mux2 #(parameter WIDTH = 8) (
    input wire [WIDTH-1:0] d0,
    input wire [WIDTH-1:0] d1,
    input wire s,
    output wire [WIDTH-1:0] y
);
    assign y = s ? d1 : d0;
endmodule

module mux3 #(parameter WIDTH = 8) (
    input wire [WIDTH-1:0] d0,
    input wire [WIDTH-1:0] d1,
    input wire [WIDTH-1:0] d2,
    input wire [1:0] s,
    output wire [WIDTH-1:0] y
);
    assign y = s[1] ? d2 : (s[0] ? d1 : d0);
endmodule

module mux4 #(parameter WIDTH = 8) (
    input wire [WIDTH-1:0] d0,
    input wire [WIDTH-1:0] d1,
    input wire [WIDTH-1:0] d2,
    input wire [WIDTH-1:0] d3,
    input wire [1:0] s,
    output reg [WIDTH-1:0] y
);
    always @(*) begin
        case(s)
            2'b00: y = d0;
            2'b01: y = d1;
            2'b10: y = d2;
            2'b11: y = d3;
        endcase
    end
endmodule
