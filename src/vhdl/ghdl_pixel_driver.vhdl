--
-- Written by
--    Paul Gardner-Stephen <hld@c64.org>  2018
--
-- *  This program is free software; you can redistribute it and/or modify
-- *  it under the terms of the GNU Lesser General Public License as
-- *  published by the Free Software Foundation; either version 3 of the
-- *  License, or (at your option) any later version.
-- *
-- *  This program is distributed in the hope that it will be useful,
-- *  but WITHOUT ANY WARRANTY; without even the implied warranty of
-- *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- *  GNU General Public License for more details.
-- *
-- *  You should have received a copy of the GNU Lesser General Public License
-- *  along with this program; if not, write to the Free Software
-- *  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
-- *  02111-1307  USA.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;
use Std.TextIO.all;
use work.debugtools.all;

entity pixel_driver is

  port (
    -- The various clocks we need
    clock100 : in std_logic;
    clock40 : in std_logic;
    clock30 : in std_logic;

    -- Inform VIC-IV of new rasters and new frames
    x_zero_out : out std_logic;
    y_zero_out : out std_logic;
    
    waddr_out : out unsigned(11 downto 0);
    wr_ack : out std_logic;
    fifo_full : out std_logic;
    rd_data_count : out std_logic_vector(9 downto 0);
    wr_data_count : out std_logic_vector(9 downto 0);
    
    -- 800x600@50Hz if pal50_select='1', else 800x600@60Hz
    pal50_select : in std_logic;
    -- Shows simple test pattern if '1', else shows normal video
    test_pattern_enable : in std_logic;
    -- Invert hsync or vsync signals if '1'
    hsync_invert : in std_logic;
    vsync_invert : in std_logic;
    
    -- Incoming video, e.g., from VIC-IV and rain compositer
    -- Clocked at clock100 (aka pixelclock)
    pixel_strobe_in : in std_logic;
    red_i : in unsigned(7 downto 0);
    green_i : in unsigned(7 downto 0);
    blue_i : in unsigned(7 downto 0);

    -- Output video stream, clocked at correct clock for the
    -- video mode, i.e., after clock domain crossing
    red_o : out unsigned(7 downto 0);
    green_o : out unsigned(7 downto 0);
    blue_o : out unsigned(7 downto 0);
    -- hsync and vsync signals for VGA
    hsync : out std_logic;
    vsync : out std_logic;

    -- Signals for VIC-IV etc to know what is happening
    hsync_uninverted : out std_logic;
    vsync_uninverted : out std_logic;
    y_zero : out std_logic;
    x_zero : out std_logic;
    inframe : out std_logic;
    
    -- Indicate when next pixel/raster is expected
    pixel_strobe_out : out std_logic;
    
    -- Similar signals to above for the LCD panel
    -- The main difference is that we only announce pixels during the 800x480
    -- letter box that the LCD can show.
    lcd_hsync : out std_logic;
    lcd_vsync : out std_logic;
    lcd_display_enable : out std_logic;
    lcd_pixel_strobe : out std_logic;     -- in 30/40MHz clock domain to match pixels
    lcd_inframe : out std_logic
    
    );

end pixel_driver;

architecture greco_roman of pixel_driver is

  signal fifo_inuse : std_logic := '0';
  signal fifo_almost_empty : std_logic := '0';
  signal fifo_running : std_logic := '0';
  signal fifo_rst : std_logic := '1';
  signal reset_counter : integer range 0 to 255 := 255;
  signal fifo_empty : std_logic := '0';   
  
  signal raster_strobe : std_logic := '0';
  signal inframe_internal : std_logic := '0';
  
  signal pal50_select_internal : std_logic := '0';

  signal wr_en : std_logic := '0';
  signal waddr : integer := 0;
  signal wdata : unsigned(31 downto 0);

  signal raddr : integer := 0;
  signal raddr50 : integer := 0;
  signal raddr60 : integer := 0;
  signal rd_clk : std_logic := '0';
  signal rd_en : std_logic := '0';
  signal rdata : unsigned(31 downto 0);  
  
  signal raster_toggle : std_logic := '0';
  signal raster_toggle_last : std_logic := '0';

  signal hsync_pal50 : std_logic := '0';
  signal hsync_pal50_uninverted : std_logic := '0';
  signal vsync_pal50 : std_logic := '0';
  signal vsync_pal50_uninverted : std_logic := '0';
  
  signal hsync_ntsc60 : std_logic := '0';
  signal hsync_ntsc60_uninverted : std_logic := '0';
  signal vsync_ntsc60 : std_logic := '0';
  signal vsync_ntsc60_uninverted : std_logic := '0';

  signal lcd_vsync_pal50 : std_logic := '0';
  signal lcd_vsync_ntsc60 : std_logic := '0';
  
  signal test_pattern_red : unsigned(7 downto 0) := x"00";
  signal test_pattern_green : unsigned(7 downto 0) := x"00";
  signal test_pattern_blue : unsigned(7 downto 0) := x"00";

  signal x_zero_pal50 : std_logic := '0';
  signal y_zero_pal50 : std_logic := '0';
  signal x_zero_ntsc60 : std_logic := '0';
  signal y_zero_ntsc60 : std_logic := '0';

  signal inframe_pal50 : std_logic := '0';
  signal inframe_ntsc60 : std_logic := '0';

  signal lcd_inframe_pal50 : std_logic := '0';
  signal lcd_inframe_ntsc60 : std_logic := '0';

  signal test_pattern_red50 : unsigned(7 downto 0) := x"00";
  signal test_pattern_green50 : unsigned(7 downto 0) := x"00";
  signal test_pattern_blue50 : unsigned(7 downto 0) := x"00";
  signal test_pattern_red60 : unsigned(7 downto 0) := x"00";
  signal test_pattern_green60 : unsigned(7 downto 0) := x"00";
  signal test_pattern_blue60 : unsigned(7 downto 0) := x"00";

  signal raster_toggle50 : std_logic := '0';
  signal raster_toggle60 : std_logic := '0';
  signal raster_toggle_last50 : std_logic := '0';
  signal raster_toggle_last60 : std_logic := '0';

  signal plotting : std_logic := '0';
  signal plotting50 : std_logic := '0';
  signal plotting60 : std_logic := '0';

  signal y_zero_internal : std_logic := '0';
  
begin

  -- Here we generate the frames and the pixel strobe references for everything
  -- that needs to produce pixels, and then buffer the pixels that arrive at pixelclock
  -- in an async FIFO, and then emit the pixels at the appropriate clock rate
  -- for the video mode.  Video mode selection is via a simple PAL/NTSC input.

  frame50: entity work.frame_generator
    generic map ( frame_width => 959,
                  display_width => 800,
                  frame_height => 625,
                  pipeline_delay => 0,
                  display_height => 600,
                  vsync_start => 620,
                  vsync_end => 625,
                  hsync_start => 814,
                  hsync_end => 884
                  )                  
    port map ( clock => clock30,
               hsync => hsync_pal50,
               hsync_uninverted => hsync_pal50_uninverted,
               vsync => vsync_pal50,
               hsync_polarity => hsync_invert,
               vsync_polarity => vsync_invert,
               x_zero => x_zero_pal50,
               y_zero => y_zero_pal50,
--               pixel_strobe => pixel_strobe50,
               inframe => inframe_pal50,               
               lcd_vsync => lcd_vsync_pal50,
               lcd_inframe => lcd_inframe_pal50
               );

  frame60: entity work.frame_generator
    generic map ( frame_width => 1056,
                  display_width => 800,
                  frame_height => 628,
                  display_height => 600,
                  pipeline_delay => 0,
                  vsync_start => 624,
                  vsync_end => 628,
                  hsync_start => 840,
                  hsync_end => 968
                  )                  
    port map ( clock => clock40,
               hsync_polarity => hsync_invert,
               vsync_polarity => vsync_invert,
               hsync_uninverted => hsync_ntsc60_uninverted,
               hsync => hsync_ntsc60,
               vsync => vsync_ntsc60,
               x_zero => x_zero_ntsc60,
               y_zero => y_zero_ntsc60,
--               pixel_strobe => pixel_strobe60,
               inframe => inframe_ntsc60,
               lcd_vsync => lcd_vsync_ntsc60,
               lcd_inframe => lcd_inframe_ntsc60

               );               
  
  hsync <= hsync_pal50 when pal50_select_internal='1' else hsync_ntsc60;
  vsync <= vsync_pal50 when pal50_select_internal='1' else vsync_ntsc60;
  lcd_vsync <= vsync_pal50 when pal50_select_internal='1' else lcd_vsync_ntsc60;
  inframe <= inframe_pal50 when pal50_select_internal='1' else inframe_ntsc60;
  inframe_internal <= inframe_pal50 when pal50_select_internal='1' else inframe_ntsc60;
  lcd_inframe <= lcd_inframe_pal50 when pal50_select_internal='1' else lcd_inframe_ntsc60;

  raster_strobe <= x_zero_pal50 when pal50_select_internal='1' else x_zero_ntsc60;
  x_zero <= x_zero_pal50 when pal50_select_internal='1' else x_zero_ntsc60;
  y_zero <= y_zero_pal50 when pal50_select_internal='1' else y_zero_ntsc60;
  y_zero_internal <= y_zero_pal50 when pal50_select_internal='1' else y_zero_ntsc60;
  
  -- Generate output pixel strobe and signals for read-side of the FIFO
  pixel_strobe_out <= clock30 when pal50_select_internal='1' else clock40;
  rd_en <= fifo_running;
  raddr <= raddr50 when pal50_select_internal='1' else raddr60;
  rd_clk <= clock30 when pal50_select_internal='1' else clock40;

  plotting <= '0' when y_zero_internal='1' else
              plotting50 when pal50_select_internal='1'
              else plotting60;
  
  -- Output the pixels or else the test pattern
  red_o <= red_i;
  green_o <= green_i;
  blue_o <= blue_i;
  
  x_zero_out <= x_zero_pal50 when pal50_select='1' else x_zero_ntsc60;
  y_zero_out <= y_zero_pal50 when pal50_select='1' else y_zero_ntsc60;
  
  process (clock100,clock30,clock40) is
    variable waddr_unsigned : unsigned(11 downto 0) := to_unsigned(0,12);
  begin

    if rising_edge(clock100) then
      pal50_select_internal <= pal50_select;
    end if;
        
    if rising_edge(clock30) then
      if x_zero_pal50='1' or fifo_inuse='0' or fifo_empty='1' then
        raddr50 <= 0;
        plotting50 <= '0';
        report "raddr = ZERO";
      else
        if raddr50 < 800 then
          if fifo_almost_empty='0' then
            plotting50 <= '1';
          end if;
        else
          plotting50 <= '0';
        end if;
        if raddr50 < 1023 then
          raddr50 <= raddr50 + 1;
        end if;
      end if;
    end if;

    if rising_edge(clock40) then
      if x_zero_ntsc60='1' or fifo_inuse='0' or fifo_empty='1' then
        raddr60 <= 0;
        plotting60 <= '0';
        report "raddr = ZERO";
      else
        if raddr60 < 800 then
          if fifo_almost_empty='0' then
            plotting60 <= '1';
          end if;
        else
          plotting60 <= '0';
        end if;
        if raddr60 < 1023 then
          raddr60 <= raddr60 + 1;
        end if;
      end if;
    end if;
    
    -- Manage writing into the raster buffer
    if rising_edge(clock100) then
      if reset_counter /= 0 then
        reset_counter <= reset_counter - 1;
        if reset_counter = 32 then
          fifo_rst <= '0';
        end if;
      else
        fifo_running <= '1';
      end if;
      if pixel_strobe_in='1' then
        waddr_unsigned := to_unsigned(waddr,12);
        waddr_out <= to_unsigned(waddr,12);
--        if waddr_unsigned(0)='1' then
--          wdata(31 downto 12) <= (others => '1');
--          wdata(11 downto 0) <= waddr_unsigned;
--        else
--          wdata(31 downto 12) <= (others => '0');
--          wdata(11 downto 0) <= waddr_unsigned;
--        end if;
        if raster_strobe = '0' then
          fifo_inuse <= not fifo_almost_empty;
          if waddr < 1023 then
            waddr <= waddr + 1;
          end if;
        else
          waddr <= 0;
          fifo_inuse <= '0';
          report "Zeroing waddr";
        end if;
        report "waddr = $" & to_hstring(to_unsigned(waddr,16));
        wr_en <= '1' and fifo_running;
      else
        wr_en <= '0';
      end if;
    end if;
    
  end process;
  
end greco_roman;