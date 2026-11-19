`timescale 1ns/1fs

// DVI-compatible video receiver. It uses only the four output pairs.
module ironvideo_serial_receiver #(parameter bit MODE_1080 = 0, parameter int FORMAT_ID = 0,
  parameter int STRIDE = (MODE_1080 ? 1920 : 1280)*4) (
  input wire clk_p, clk_n,
  input wire [2:0] data_p, data_n,
  output logic checked = 0
);
  localparam realtime PIXEL_PERIOD = MODE_1080 ? 1000ns / 148.5 : 1000ns / 74.25;
  localparam int H_ACTIVE = MODE_1080 ? 1920 : 1280, V_ACTIVE = MODE_1080 ? 1080 : 720;
  localparam int H_TOTAL = MODE_1080 ? 2200 : 1650, V_TOTAL = MODE_1080 ? 1125 : 750;
  localparam int HS_START = MODE_1080 ? 2008 : 1390, HS_END = MODE_1080 ? 2052 : 1430;
  localparam int VS_START = MODE_1080 ? 1084 : 725, VS_END = MODE_1080 ? 1089 : 730;
  realtime previous_edge = 0;

  // TMDS control codes are ordered by {VS, HS} (DVI 1.0, section 3.2.2).
  function automatic logic [9:0] control(input logic vs, hs);
    case ({vs, hs})
      2'b00: return 10'b1101010100;
      2'b01: return 10'b0010101011;
      2'b10: return 10'b0101010100;
      2'b11: return 10'b1010101011;
    endcase
  endfunction

  function automatic bit is_control(input logic [9:0] symbol);
    for (int code = 0; code < 4; code++)
      if (symbol === control(code[1], code[0])) return 1;
    return 0;
  endfunction

  // Reverse the inversion bit, then recover consecutive transition bits.
  function automatic logic [7:0] decode(input logic [9:0] symbol);
    logic [7:0] payload;
    payload = symbol[7:0] ^ {8{symbol[9]}};
    return {payload[7:1] ^ payload[6:0] ^ {7{!symbol[8]}}, payload[0]};
  endfunction

  // DVI 1.0 section 3.2.2 selects the transition-minimized payload and then
  // encodes it with a running DC disparity. Validate both choices on the wire.
  task automatic check_video_symbol(input logic [9:0] symbol, input logic [7:0] pixel,
                                    inout int running_disparity);
    logic [7:0] payload;
    bit use_xor, invert_payload;
    int payload_disparity;

    // The seven transitions with XOR correspond to pixel[7:1]. XNOR
    // complements them, so XOR wins when fewer than four bits are set.
    use_xor = $countones(pixel[7:1]) < 4;
    payload = symbol[7:0] ^ {8{symbol[9]}};
    payload_disparity = 2 * $countones(payload) - 8;
    invert_payload = !use_xor;
    if (running_disparity != 0 && payload_disparity != 0)
      invert_payload = (running_disparity > 0) == (payload_disparity > 0);
    if (symbol[9:8] !== {invert_payload, use_xor})
      $fatal(1, "TEST FAIL: illegal TMDS video symbol %h for pixel %h at disparity %0d, expected bits [9:8] %b%b",
             symbol, pixel, running_disparity, invert_payload, use_xor);
    running_disparity += 2 * $countones(symbol) - 10;
  endtask

  task automatic receive_word(output logic [9:0] red, green, blue);
    realtime edge_time, bit_period;
    @(negedge clk_p);
    edge_time = $realtime;
    if (previous_edge != 0 &&
        (edge_time - previous_edge < PIXEL_PERIOD - 0.002ns ||
         edge_time - previous_edge > PIXEL_PERIOD + 0.002ns))
      $fatal(1, "TEST FAIL: forwarded clock period %0.6f ns at %0t", edge_time - previous_edge, $time);
    bit_period = previous_edge == 0 ? PIXEL_PERIOD / 10 : (edge_time - previous_edge) / 10;
    previous_edge = edge_time;
    #(bit_period / 2);
    for (int bit_index = 0; bit_index < 10; bit_index++) begin
      if (clk_p !== (bit_index >= 5) || clk_n !== !clk_p ||
          data_n !== ~data_p || (^data_p === 1'bx))
        $fatal(1, "TEST FAIL: TMDS differential or clock phase at bit %0d, time %0t", bit_index, $time);
      {red[bit_index], green[bit_index], blue[bit_index]} = data_p;
      if (bit_index != 9) #(bit_period);
    end
  endtask

  initial begin : check_stream
    logic [9:0] red, green, blue;
    logic [23:0] expected_rgb;
    logic expected_hs, expected_vs;
    realtime frame_start, first_start;
    int word_number = 0;
    int red_disparity = 0, green_disparity = 0, blue_disparity = 0;

    // Wait for glbl GSR/serializer startup and lock the raster on the first DE.
    #300ns;
    do receive_word(red, green, blue); while (is_control(red));
    first_start = previous_edge;
    for (int frame = 0; frame < 3; frame++) begin
      frame_start = previous_edge;
      for (int y = 0; y < V_TOTAL; y++) begin
        for (int x = 0; x < H_TOTAL; x++) begin
          if (x < H_ACTIVE && y < V_ACTIVE) begin
            expected_rgb = frame == 0 ? 24'b0 : ironvideo_format_model::color(FORMAT_ID,x,y,STRIDE);
            if (is_control(red) || is_control(green) || is_control(blue) ||
                {decode(red), decode(green), decode(blue)} !== expected_rgb)
              $fatal(1, "TEST FAIL: TMDS frame %0d pixel (%0d,%0d), RGB symbols %h/%h/%h expected RGB %h",
                     frame, x, y, red, green, blue, expected_rgb);
            check_video_symbol(red, expected_rgb[23:16], red_disparity);
            check_video_symbol(green, expected_rgb[15:8], green_disparity);
            check_video_symbol(blue, expected_rgb[7:0], blue_disparity);
          end else begin
            expected_hs = x >= HS_START && x < HS_END;
            expected_vs = y >= VS_START && y < VS_END;
            if (red !== control(0, 0) || green !== control(0, 0) ||
                blue !== control(expected_vs, expected_hs))
              $fatal(1, "TEST FAIL: TMDS frame %0d blanking (%0d,%0d), RGB symbols %h/%h/%h expected HS/VS %b/%b",
                     frame, x, y, red, green, blue, expected_hs, expected_vs);
            red_disparity = 0;
            green_disparity = 0;
            blue_disparity = 0;
          end
          word_number++;
          receive_word(red, green, blue);
        end
      end
      if (previous_edge - frame_start < 16666645ns || previous_edge - frame_start > 16666688ns)
        $fatal(1, "TEST FAIL: TMDS frame %0d duration %0.6f ns", frame, previous_edge - frame_start);
      $display("%m TMDS frame %0d verified, duration %0.6f ns, elapsed %0.6f ns",
               frame, previous_edge - frame_start, previous_edge - first_start);
    end
    expected_rgb = ironvideo_format_model::color(FORMAT_ID,0,0,STRIDE);
    if ({decode(red), decode(green), decode(blue)} !== expected_rgb ||
        is_control(red) || is_control(green) || is_control(blue))
      $fatal(1, "TEST FAIL: TMDS stream did not continue at the next frame boundary");
    check_video_symbol(red, expected_rgb[23:16], red_disparity);
    check_video_symbol(green, expected_rgb[15:8], green_disparity);
    check_video_symbol(blue, expected_rgb[7:0], blue_disparity);
    word_number++;
    $display("%m %0d serialized TMDS words verified", word_number);
    checked = 1;
  end
endmodule
