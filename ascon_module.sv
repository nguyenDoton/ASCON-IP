`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/07/2026 05:56:45 PM
// Design Name: 
// Module Name: ascon_module
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module ascon_module(
    input logic clk,
    input logic rst_n,
    input logic ascon_invoke,

    input logic ascon_mode, //0-ascon128, 1-ascon128a
    input logic [127:0] key,   //K
    input logic [127:0] nonce, //N
    
    //PS-DMA signals
    input logic s_axi_tvalid,  
    input logic [63:0] s_axi_tdata,
    input logic s_axi_tlast,
    output logic s_axi_tready,

    //ASCON-DMA signals
    input logic m_axi_tready,
    output logic m_axi_tvalid,
    output logic [63:0] m_axi_tdata,
    output logic m_axi_tlast

    );

    localparam logic [63:0] IV_ASCON128  = 64'h80400c0600000000;
    localparam logic [63:0] IV_ASCON128A = 64'h80800c0800000000;
   
    logic [63:0] selected_vect;
    logic [63:0] key_buffer; //second half(64 bits) of the key
    always_comb begin 
        if(ascon_mode == 1'b0) selected_vect = IV_ASCON128;
        else  selected_vect = IV_ASCON128A;
    end
    
    logic         perm_start;
    logic [3:0]   perm_rounds; // Tells permutation module to run 12, 8, or 6 rounds
    logic         perm_done;
    
    // 1. The Master Bucket (Controlled ONLY by the FSM)
    logic [319:0] ascon_state;
    logic last_packet;
    logic handled_last;
    logic [63:0] s_tdata_swapped; //handling endianness
    logic [63:0] m_tdata_internal; //handling endianness

    // 2. A wire to catch the output from the permutation module
    logic [319:0] perm_out_wire;
    
    // 3. Instantiate the engine
    permutation u_perm_engine (
        .clk         (clk),
        .rst_n       (rst_n),
        .perm_start  (perm_start),
        .num_round   (perm_rounds),
        .input_state (ascon_state), // Engine constantly reads the master bucket
        .output_state(perm_out_wire),      // Engine spits scrambled data onto this wire
        .perm_done   (perm_done)
    );
    
    typedef enum logic [4:0] { 
        IDLE,

        // Initialization 
        INIT_START,     // Load IV/Key/Nonce, perm_start = 1 (12 rounds)
        INIT_WAIT,      // Wait for perm_done
        INIT_FINISH,    // XOR Key into bottom 128 bits

        //  Associated Data 
        // For your IoT Node, this might just be header bytes
        AD_ABSORB,      // Wait for AXI tvalid, gulp 64 bits, XOR into state[0]
        AD_PROCESS,     // perm_start = 1 (8 rounds for ASCON-128)
        AD_PAD,
        AD_PAD_WAIT,
        AD_WAIT,        // Wait for perm_done
        AD_TRANSITION,  // Domain separation: XOR 1 into LSB of state[4]
         
        // Plaintext / Ciphertext 
        // This is where your NPU stream flows in
        PT_ABSORB,    // Wait for AXI tvalid, XOR NPU data into state[0]
        PT_PAD,       //Padding the ascon state
        PT_SEND,
        PT_PROCESS,     // perm_start = 1 (8 rounds)
        PT_WAIT,        // Wait for perm_done

        // Finalization
        FINAL_START,    // XOR Key into state[1] & state[2], perm_start = 1 (12 rounds)
        FINAL_WAIT,     // Wait for perm_done
        FINAL_TAG_FIRST,
        FINAL_TAG_SECOND       // Output the final 128-bit Tag!
    } state_t;

    state_t current_state;

    
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
           ascon_state <= 320'b0;
           perm_start <= 1'b0;
           perm_rounds <= 4'b0;
           current_state <= IDLE;
           handled_last <= 1'b0;
           last_packet <= 1'b0;
        end

        else begin  
            //Initialization  
            perm_start <= 1'b0;
            case(current_state) 
            IDLE: begin 
                perm_start <= 1'b0;
                m_axi_tvalid <= 1'b0;
                m_axi_tlast  <= 1'b0;
                last_packet  <= 1'b0;
                handled_last <= 1'b0;
                if(ascon_invoke) begin
                current_state <= INIT_START;
                end
            end
            INIT_START: begin
                perm_start <= 1'b1;
                ascon_state <= {selected_vect, key, nonce};
                perm_rounds <= 4'd12;
                current_state <= INIT_WAIT;
            end
            INIT_WAIT: begin
                if(perm_done) begin 
                current_state <= INIT_FINISH;
                ascon_state <= perm_out_wire;
                perm_start <= 1'b0;
                end  
            end
            INIT_FINISH: begin
                current_state<= AD_ABSORB;
                ascon_state <= ascon_state ^ {192'b0,key};
            end 
            AD_ABSORB: begin
                if(s_axi_tvalid) begin
                    last_packet <= s_axi_tlast;
                    ascon_state[319:256] <= ascon_state[319:256] ^ s_tdata_swapped;
                    current_state <= AD_PROCESS;    
                end
            end
            AD_PAD:begin
                ascon_state[319:256] <= ascon_state[319:256] ^ {1'b1,63'b0};
                handled_last <= 1'b1;
                current_state <= AD_PAD_WAIT;    
            end
            AD_PAD_WAIT: begin
                current_state <= AD_PROCESS;
            end
            AD_PROCESS: begin
                perm_start <= 1'b1;
                if(ascon_mode) perm_rounds <= 4'd8;
                else perm_rounds <= 4'd6;
                if(handled_last) last_packet <= 1'b0;
                current_state <= AD_WAIT;
            end
            
            AD_WAIT: if(perm_done) begin
                ascon_state <= perm_out_wire;
                perm_start <= 1'b0;
                if(last_packet) begin
                    current_state <= AD_PAD;
                end
                else begin
                    if(handled_last) begin
                        handled_last <= 1'b0;
                        current_state <= AD_TRANSITION;
                    end
                    else current_state <= AD_ABSORB;
                end
            end
            AD_TRANSITION: begin
                current_state <= PT_ABSORB;  
                ascon_state <= ascon_state ^ {319'b0,1'b1};
            end 
            //Review tomorrow
            PT_ABSORB: begin
                if(s_axi_tvalid) begin
                    last_packet <= s_axi_tlast;
                    ascon_state[319:256] <= ascon_state[319:256] ^ s_tdata_swapped;
                    m_tdata_internal <= ascon_state[319:256] ^ s_tdata_swapped; //ciphertext sent
                    m_axi_tvalid <= 1'b1;
                    current_state <= PT_SEND;   
                end
            end
            PT_SEND:begin
                if(m_axi_tready) begin
                    current_state <= PT_PROCESS;
                    m_axi_tvalid <= 1'b0;
                end
            end
            PT_PAD: begin
                ascon_state[319:256] <= ascon_state[319:256] ^ {1'b1,63'b0};
                current_state <= FINAL_START;    
            end
            PT_PROCESS: begin
                perm_start <= 1'b1;
                if(ascon_mode) perm_rounds <= 4'd8;
                else perm_rounds <= 4'd6;
                current_state <= PT_WAIT;
            end
            PT_WAIT: begin
                if(perm_done) begin
                    ascon_state <= perm_out_wire;
                    perm_start <= 1'b0;
                    if(last_packet) begin
                        last_packet <= 1'b0; 
                        current_state <= PT_PAD; 
                    end
                    else begin
                        current_state <= PT_ABSORB; 
                    end
                end
            end
            FINAL_START: begin
                ascon_state <= ascon_state ^ {64'b0,key,128'b0};
                perm_start <= 1'b1;
                perm_rounds <= 4'd12;
                current_state <= FINAL_WAIT;
            end

            FINAL_WAIT: begin
                if(perm_done) begin
                    ascon_state <= perm_out_wire;
                    current_state <= FINAL_TAG_FIRST;
                    perm_start <= 1'b0;
                    m_axi_tvalid <= 1'b1;
                    key_buffer <= perm_out_wire[63:0] ^ key[63:0];
                    m_tdata_internal <= perm_out_wire[127:64] ^ key[127:64];
                end
            end
            FINAL_TAG_FIRST: begin 
                if(m_axi_tready) begin
                    current_state <= FINAL_TAG_SECOND;
                    m_axi_tlast <= 1'b1;
                    m_tdata_internal <= key_buffer;
                end
            end
            FINAL_TAG_SECOND: begin
                if(m_axi_tready) begin
                    m_axi_tvalid <= 1'b0;
                    m_axi_tlast <= 1'b0;
                    current_state <= IDLE;
                end
            end
            default: current_state <= IDLE;



            endcase
        end
    end
    assign s_tdata_swapped = {s_axi_tdata[7:0], s_axi_tdata[15:8],s_axi_tdata[23:16],s_axi_tdata[31:24],s_axi_tdata[39:32],s_axi_tdata[47:40],s_axi_tdata[55:48],s_axi_tdata[63:56]};
    assign s_tready = (current_state == AD_ABSORB) || (current_state == PT_ABSORB);
    assign m_tdata = {m_tdata_internal[7:0],  m_tdata_internal[15:8], m_tdata_internal[23:16], m_tdata_internal[31:24], 
                      m_tdata_internal[39:32], m_tdata_internal[47:40], m_tdata_internal[55:48], m_tdata_internal[63:56]};
endmodule

module permutation(
    input logic clk,
    input logic rst_n,

    input logic perm_start,
    input logic [3:0] num_round,
    input logic [319:0] input_state,
    output logic [319:0] output_state,
    output logic perm_done

); 
    logic [319:0] state;
    logic [3:0] round_count;
    logic [7:0] round_constant;
    logic       busy;

    always_comb begin //accumulation constant
        case (round_count)
            4'd0:  round_constant = 8'hf0;
            4'd1:  round_constant = 8'he1;
            4'd2:  round_constant = 8'hd2;
            4'd3:  round_constant = 8'hc3;
            4'd4:  round_constant = 8'hb4;
            4'd5:  round_constant = 8'ha5;
            4'd6:  round_constant = 8'h96;
            4'd7:  round_constant = 8'h87;
            4'd8:  round_constant = 8'h78;
            4'd9:  round_constant = 8'h69;
            4'd10: round_constant = 8'h5a;
            4'd11: round_constant = 8'h4b;
            default: round_constant = 8'h00;
        endcase
    end
    
    logic [63:0] x0_out, x1_out,x2_out,x3_out,x4_out;
    logic [63:0] x0,x1,x2,x3,x4;
    logic [63:0] t0,t1,t2,t3,t4;
    
    //Ascon S-box
    always_comb begin
 
        x0 = state[319:256];
        x1 = state[255:192];
        x2 = state[191:128];
        x3 = state[127:64];
        x4 = state[63:0];

        //Accumulation round
        x2[7:0] = x2[7:0] ^ round_constant;  

        //Subtitution round
        /*x0 = x0 ^ x4;
        t0 = x0;
        x2 = x2 ^ x1;
        t2 = x2;
        x4 = x4 ^ x3;
        t4 = x4;
        t1 = x1 ^ (~x2 & x3);
        t3 = x3 ^ (~x4 & t0);
        t0 = t0 ^ (t2 & ~x1);
        t2 = t2 ^ (~x3 & t4);
        t4 = t4 ^ (~x0 & x1);
        */
        // Step 1
        x0 = x0 ^ x4;
        x2 = x2 ^ x1;
        x4 = x4 ^ x3;

        // Step 2 (snapshot)
        t0 = x0;
        t1 = x1;
        t2 = x2;
        t3 = x3;
        t4 = x4;

        // Step 3 (ONLY t's!)
        t1 = t1 ^ (~t2 & t3);
        t3 = t3 ^ (~t4 & t0);
        t0 = t0 ^ (~t1 & t2);
        t2 = t2 ^ (~t3 & t4);
        t4 = t4 ^ (~t0 & t1);



        //Subtitution round output
        x0 = t0 ^ t4;
        x1 = t1 ^ t0;
        x2 = ~t2;
        x3 = t2 ^ t3;
        x4 = t4;

        //Linear round
        x0_out = x0 ^ {x0[18:0],x0[63:19]} ^ { x0[27:0],x0[63:28]};
        x1_out = x1 ^ {x1[60:0],x1[63:61]} ^ { x1[38:0],x1[63:39]};
        x2_out = x2 ^ {x2[0],x2[63:1]} ^ { x2[5:0],x2[63:6]};
        x3_out = x3 ^ {x3[9:0],x3[63:10]} ^ { x3[16:0],x3[63:17]};
        x4_out = x4 ^ {x4[6:0],x4[63:7]} ^ { x4[40:0],x4[63:41]};
    end



    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state <= 320'b0;
            round_count <= 4'b0;
            busy <= 1'b0;
            perm_done <= 1'b0;
        end
        else begin
            perm_done <= 1'b0;

            if(perm_start & !busy) begin
                state <= input_state;
                round_count <= 4'b1100 - num_round;
                busy <= 1'b1;
            end
            
            else if (busy) begin
                state[319:256] <= x0_out;
                state[255:192] <= x1_out;
                state[191:128] <= x2_out;
                state[127:64]  <= x3_out;
                state[63:0]    <= x4_out;
                

                
                //Linear round

                if(round_count == 4'b1011) begin
                   busy <= 1'b0;
                   perm_done <= 1'b1;
                end
                else begin
                   round_count <= round_count + 4'b1;
                end
            end
        end
    end

    assign output_state = state;
   
endmodule
