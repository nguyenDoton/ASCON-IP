`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/15/2026 12:47:34 AM
// Design Name: 
// Module Name: ascon_tb
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


module ascon_tb;
// 1. Module Connections (Wires and Regs)
    logic clk;
    logic rst_n;
    
    // Control Signals
    logic ascon_invoke;
    logic ascon_mode;
    logic [127:0] key;
    logic [127:0] nonce;
    
    // AXI-Stream Input (Simulated NPU/PS -> ASCON)
    logic s_tvalid;
    logic [63:0] s_tdata;
    logic s_tlast;
    logic s_tready;
    
    // AXI-Stream Output (ASCON -> Simulated DMA)
    logic m_tready;
    logic m_tvalid;
    logic [63:0] m_tdata;
    logic m_tlast;

    // 2. Instantiate Your Masterpiece
    ascon_module uut (
        .clk(clk),
        .rst_n(rst_n),
        .ascon_invoke(ascon_invoke),
        .ascon_mode(ascon_mode),
        .key(key),
        .nonce(nonce),
        
        .s_tvalid(s_tvalid),
        .s_tdata(s_tdata),
        .s_tlast(s_tlast),
        .s_tready(s_tready),
        
        .m_tready(m_tready),
        .m_tvalid(m_tvalid),
        .m_tdata(m_tdata),
        .m_tlast(m_tlast)
    );

    // 3. Clock Generation (100 MHz)
    always #5 clk = ~clk;

    // ---------------------------------------------------------
    // THE MONITOR (Simulating the downstream DMA)
    // ---------------------------------------------------------
    initial begin
        m_tready = 1'b0;
        
        @(posedge rst_n); // Wait for system to power up
        
        // STRESS TEST: We randomly drop m_tready to 0 to prove your 
        // PT_SEND and FINAL_TAG states hold the data safely!
        forever begin
            @(posedge clk);
            
            // 70% chance the DMA is ready, 30% chance it stalls your module
            m_tready = ($urandom_range(0, 9) > 2) ? 1'b1 : 1'b0;
            
            // If a successful handshake happens, print it to the console
            if (m_tvalid && m_tready) begin
                $display("[%0t ns] DMA Caught Data: 0x%h | tlast: %b", $time, m_tdata, m_tlast);
                
                if (m_tlast) begin
                    $display("========================================");
                    $display(" ENCRYPTION COMPLETE. 128-BIT TAG RECEIVED.");
                    $display("========================================");
                end
            end
        end
    end
    logic init_printed;

        initial init_printed = 0;

        always @(posedge clk) begin
        if (!init_printed && uut.current_state == uut.INIT_FINISH) begin
        #1; // small delay to let non-blocking assignments settle

        $display("========================================");
        $display(" STATE AFTER INIT (RTL)");
        $display("S0 = %016h", uut.ascon_state[319:256]);
        $display("S1 = %016h", uut.ascon_state[255:192]);
        $display("S2 = %016h", uut.ascon_state[191:128]);
        $display("S3 = %016h", uut.ascon_state[127:64]);
        $display("S4 = %016h", uut.ascon_state[63:0]);
        $display("========================================");

        init_printed = 1;
        end
        end

    logic ad1_printed, ad2_printed, pt1_printed;
logic pt2_printed, pt3_printed, final_printed;

always @(posedge clk) begin
    #1;

    if (s_tvalid) begin
        $display("========================================");
        $display("🔍 INPUT SEEN (VALID)");

        $display("STATE = %s", state_to_string(uut.current_state));
        $display("s_tvalid=%0b s_tready=%0b", s_tvalid, s_tready);

        $display("Before XOR S0 = %016h", uut.ascon_state[319:256]);
        $display("Incoming Data = %016h", s_tdata);

        $display("Expected After XOR = %016h",
                 uut.ascon_state[319:256] ^ s_tdata);

        $display("========================================");
    end
end

initial begin
    ad1_printed = 0;
    ad2_printed = 0;
    pt1_printed = 0;
    pt2_printed = 0;
    pt3_printed = 0;
    final_printed = 0;
end

always @(posedge clk) begin

    // =========================================
    // 2. AFTER AD FIRST PERMUTATION
    // =========================================
    if (!ad1_printed && uut.current_state == uut.AD_WAIT && uut.perm_done) begin
    #1;
    $display("========================================");
    $display(" STATE AFTER AD ABSORB (RTL)");

    $display("S0 = %016h", uut.perm_out_wire[319:256]);
    $display("S1 = %016h", uut.perm_out_wire[255:192]);
    $display("S2 = %016h", uut.perm_out_wire[191:128]);
    $display("S3 = %016h", uut.perm_out_wire[127:64]);
    $display("S4 = %016h", uut.perm_out_wire[63:0]);

    $display("========================================");
    ad1_printed = 1;
end

    // =========================================
    // 3. AFTER AD DOMAIN SEPARATION
    // =========================================
    if (!ad2_printed && uut.current_state == uut.AD_TRANSITION) begin
        #1;
        $display("========================================");
        $display(" STATE AFTER AD FINAL (RTL)");
        $display("S0 = %016h", uut.ascon_state[319:256]);
        $display("S1 = %016h", uut.ascon_state[255:192]);
        $display("S2 = %016h", uut.ascon_state[191:128]);
        $display("S3 = %016h", uut.ascon_state[127:64]);
        $display("S4 = %016h", uut.ascon_state[63:0]);
        $display("========================================");
        ad2_printed = 1;
    end

    // =========================================
    // 4. PLAINTEXT ABSORB (CIPHERTEXT)
    // =========================================
    if (!pt1_printed && uut.current_state == uut.PT_SEND) begin
        #1;
        $display("========================================");
        $display(" CIPHERTEXT (RTL)");
        $display("CT = %016h", uut.m_tdata_internal);
        $display("========================================");
        pt1_printed = 1;
    end

    // =========================================
    // 5. AFTER PT PERMUTATION
    // =========================================
    if (!pt2_printed && uut.current_state == uut.PT_WAIT && uut.perm_done) begin
        #1;
        $display("========================================");
        $display(" STATE AFTER PT PERMUTATION (RTL)");
        $display("S0 = %016h", uut.ascon_state[319:256]);
        $display("S1 = %016h", uut.ascon_state[255:192]);
        $display("S2 = %016h", uut.ascon_state[191:128]);
        $display("S3 = %016h", uut.ascon_state[127:64]);
        $display("S4 = %016h", uut.ascon_state[63:0]);
        $display("========================================");
        pt2_printed = 1;
    end

    // =========================================
    // 6. AFTER PT PADDING
    // =========================================
    if (!pt3_printed && uut.current_state == uut.PT_PAD) begin
        #1;
        $display("========================================");
        $display(" STATE AFTER PT PADDING (RTL)");
        $display("S0 = %016h", uut.ascon_state[319:256]);
        $display("S1 = %016h", uut.ascon_state[255:192]);
        $display("S2 = %016h", uut.ascon_state[191:128]);
        $display("S3 = %016h", uut.ascon_state[127:64]);
        $display("S4 = %016h", uut.ascon_state[63:0]);
        $display("========================================");
        pt3_printed = 1;
    end

    // =========================================
    // 7. FINAL STATE BEFORE TAG
    // =========================================
    if (!final_printed && uut.current_state == uut.FINAL_WAIT && uut.perm_done) begin
        #1;
        $display("========================================");
        $display(" STATE AFTER FINAL PERMUTATION (RTL)");
        $display("S0 = %016h", uut.ascon_state[319:256]);
        $display("S1 = %016h", uut.ascon_state[255:192]);
        $display("S2 = %016h", uut.ascon_state[191:128]);
        $display("S3 = %016h", uut.ascon_state[127:64]);
        $display("S4 = %016h", uut.ascon_state[63:0]);
        $display("========================================");

        $display("🔍 EXPECTED TAG (RTL)");
        $display("TAG_H = %016h", uut.perm_out_wire[127:64] ^ uut.key[127:64]);
        $display("TAG_L = %016h", uut.perm_out_wire[63:0]   ^ uut.key[63:0]);
        $display("========================================");

        final_printed = 1;
    end

end
// =========================================================
// 🔍 FULL FSM + STATE TRACE (Cycle-by-cycle debugger)
// =========================================================

// Convert enum state to readable string
function string state_to_string(input logic [4:0] st);
    case (st)
        uut.IDLE:              return "IDLE";
        uut.INIT_START:        return "INIT_START";
        uut.INIT_WAIT:         return "INIT_WAIT";
        uut.INIT_FINISH:       return "INIT_FINISH";
        uut.AD_ABSORB:         return "AD_ABSORB";
        uut.AD_PROCESS:        return "AD_PROCESS";
        uut.AD_WAIT:           return "AD_WAIT";
        uut.AD_PAD:            return "AD_PAD";
        uut.AD_PAD_WAIT:       return "AD_PAD_WAIT";
        uut.AD_TRANSITION:     return "AD_TRANSITION";
        uut.PT_ABSORB:         return "PT_ABSORB";
        uut.PT_SEND:           return "PT_SEND";
        uut.PT_PROCESS:        return "PT_PROCESS";
        uut.PT_WAIT:           return "PT_WAIT";
        uut.PT_PAD:            return "PT_PAD";
        uut.FINAL_START:       return "FINAL_START";
        uut.FINAL_WAIT:        return "FINAL_WAIT";
        uut.FINAL_TAG_FIRST:   return "FINAL_TAG_FIRST";
        uut.FINAL_TAG_SECOND:  return "FINAL_TAG_SECOND";
        default:               return "UNKNOWN";
    endcase
endfunction

logic [4:0] prev_state;
logic first_cycle;

initial begin
    prev_state = 0;
    first_cycle = 1;
end

always @(posedge clk) begin
    #1;
    if (first_cycle || uut.current_state != prev_state) begin
        first_cycle = 0;

        $display("STATE: %s", state_to_string(uut.current_state));
    end
    prev_state <= uut.current_state;
end
    // ---------------------------------------------------------
    // THE DRIVER (Simulating the ARM Processor loading data)
    // ---------------------------------------------------------
    initial begin
        // A. Initialize everything to zero
        clk = 0;
        rst_n = 0;
        ascon_invoke = 0;
        ascon_mode = 0; // 0 = ASCON-128
        
        // NIST Standard Test Key and Nonce
        key   = 128'h000102030405060708090A0B0C0D0E0F;
        nonce = 128'h000102030405060708090A0B0C0D0E0F;
        
        s_tvalid = 0;
        s_tdata = 0;
        s_tlast = 0;
        
        // B. Power On / Reset
        $display("[%0t ns] Applying Hardware Reset...", $time);
        #20 rst_n = 1;
        #20;
        
        // C. Wake up the ASCON module!
        $display("[%0t ns] CPU: Pulsing ascon_invoke...", $time);
        @(posedge clk);
        ascon_invoke = 1;
        @(posedge clk);
        ascon_invoke = 0;
        

 
        // D. Send Associated Data (AD) Phase
        // Note: Your FSM strictly routes through AD_ABSORB, so we feed it 
        // one dummy header block to trigger the state transitions.
        $display("[%0t ns] CPU: Waiting for AD phase to open...", $time);
        wait(s_tready == 1'b1);

        s_tvalid = 1;
        // s_tdata  = 64'h3832314E4F435341;
        s_tdata  = 64'h0000000000000000;
        s_tlast  = 1;

        @(posedge clk); // handshake happens HERE

        wait(s_tready && s_tvalid); // optional safety
        @(posedge clk);
        s_tvalid = 0;
        s_tlast  = 0;
        
        // E. Send Plaintext (PT) Phase
        // $display("[%0t ns] CPU: Waiting for PT phase to open...", $time);
        wait(s_tready == 1'b1);
        
        
        // $display("[%0t ns] CPU: Blasting Plaintext Payload...", $time);
        s_tvalid = 1;
        s_tdata  = 64'h0706050403020100;
        s_tlast  = 1; 
        @(posedge clk);
        wait(s_tready == 1'b1 && s_tvalid == 1'b1); // Wait for the handshake
        @(posedge clk);
        s_tvalid = 0;
        s_tlast = 0;
        
        // F. Let the simulation run out to catch the tags
        #2000;
        $display("[%0t ns] SIMULATION FINISHED.", $time);
        $finish;
    end
    
endmodule
