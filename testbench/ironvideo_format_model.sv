`timescale 1ns/1fs
// Independent framebuffer generator and displayed-color oracle. Both the
// raster scoreboard and the receiver at the differential pins use this model.
package ironvideo_format_model;
  function automatic logic [15:0] rgb565(input int x, y);
    return {5'(x + 3*y), 6'(9*x + y), 5'(3*x - y)};
  endfunction
  function automatic byte unsigned luma(input int x, y);
    return 8'(17*x + 11*y + 16);
  endfunction
  function automatic byte unsigned cb(input int pair_x, chroma_y);
    return 8'(13*pair_x + 9*chroma_y + 81);
  endfunction
  function automatic byte unsigned cr(input int pair_x, chroma_y);
    return 8'(3*pair_x - 11*chroma_y + 191);
  endfunction
  function automatic byte unsigned quantize(input int value);
    int rounded;
    rounded = (value + 128) >>> 8;
    return rounded < 0 ? 8'd0 : rounded > 255 ? 8'd255 : 8'(rounded);
  endfunction
  function automatic logic [23:0] color(input int fmt, x, y, stride);
    logic [15:0] packed565;
    int c, d, e, cy;
    case (fmt)
      0: return 24'(y * (stride/4) + x) ^ 24'h57_a9_31;
      1: begin
        packed565 = rgb565(x,y);
        return {packed565[15:11],packed565[15:13],packed565[10:5],packed565[10:9],
                packed565[4:0],packed565[4:2]};
      end
      default: begin
        cy = fmt == 3 ? y / 2 : y;
        c = int'(luma(x,y)) - 16;
        d = int'(cb(x/2,cy)) - 128;
        e = int'(cr(x/2,cy)) - 128;
        return {quantize(298*c + 459*e), quantize(298*c - 55*d - 136*e), quantize(298*c + 541*d)};
      end
    endcase
  endfunction
endpackage
