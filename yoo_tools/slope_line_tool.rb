# frozen_string_literal: true

module Yoo_Tools
  class SlopeLineTool
    OVERLAY_OFFSET_X = 50
    OVERLAY_OFFSET_Y = -50
    OVERLAY_PADDING_X = 10
    OVERLAY_PADDING_Y = 6
    FONT_SIZE = 12
    CURSOR_PENCIL = 632
    MAX_ABS_DEGREES = 89.0
    @@cursor_slope_line_id = nil

    def initialize
      @start_point = nil
      @start_ip = Sketchup::InputPoint.new
      @mouse_ip = Sketchup::InputPoint.new
      @mouse_x = 0
      @mouse_y = 0
      @slope_ratio = 0.02 # rise/run (default 2%)
      @slope_source = :percent
      @slope_source_value = 2.0
      @axis_lock = :none
    end

    def activate
      update_vcb
      update_status_text
      Sketchup.active_model.active_view.invalidate
    end

    def deactivate(_view)
      Sketchup.status_text = ''
      Sketchup.vcb_label = ''
      Sketchup.vcb_value = ''
    end

    def resume(_view)
      update_vcb
      update_status_text
    end

    def onCancel(_reason, view)
      if @start_point
        @start_point = nil
        update_status_text
        view.invalidate
      else
        view.model.select_tool(nil)
      end
    end

    def onMouseMove(_flags, x, y, view)
      @mouse_x = x
      @mouse_y = y
      @mouse_ip.pick(view, x, y)
      view.tooltip = @mouse_ip.tooltip if @mouse_ip.valid? && @mouse_ip.display?
      view.invalidate
    end

    def onLButtonDown(_flags, x, y, view)
      @mouse_ip.pick(view, x, y)
      return unless @mouse_ip.valid?

      if @start_point.nil?
        @start_point = @mouse_ip.position
        @start_ip.copy!(@mouse_ip)
        update_status_text
        view.invalidate
        return
      end

      raw_target = @mouse_ip.position
      endpoint = solve_endpoint(@start_point, raw_target)
      if endpoint.nil?
        UI.beep
        Sketchup.status_text = 'Slope line: pick a point with horizontal distance from last point.'
        return
      end

      model = view.model
      model.start_operation('Draw Slope Line', true)
      begin
        model.active_entities.add_line(@start_point, endpoint)
        model.commit_operation
      rescue StandardError => e
        model.abort_operation
        Yoo_Tools.log_debug("[SlopeLineTool] #{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}")
        UI.messagebox("Slope line failed.\n\n#{e.class}: #{e.message}")
        return
      end

      @start_point = endpoint
      update_status_text
      view.invalidate
    end

    def onSetCursor
      UI.set_cursor(cursor_id)
    rescue StandardError
      nil
    end

    def onKeyDown(key, _repeat, _flags, view)
      case key
      when 39 # right arrow -> red axis
        @axis_lock = :x
      when 37 # left arrow -> green axis
        @axis_lock = :y
      when 40 # down arrow -> unlock
        @axis_lock = :none
      else
        return
      end
      update_status_text
      view.invalidate
    end

    def enableVCB?
      true
    end

    def onUserText(text, view)
      parsed = parse_slope_input(text)
      unless parsed
        UI.beep
        Sketchup.status_text = "Invalid slope. Use formats like 12%, -7.5%, 10deg, -5d."
        return
      end

      @slope_ratio = parsed[:ratio]
      @slope_source = parsed[:source]
      @slope_source_value = parsed[:source_value]
      update_vcb
      update_status_text
      view.invalidate
    end

    def draw(view)
      @mouse_ip.draw(view) if @mouse_ip.display?
      draw_preview_segment(view)
      draw_overlay(view)
    rescue StandardError
      nil
    ensure
      begin
        view.line_width = 1
      rescue StandardError
        nil
      end
    end

    def getExtents
      Sketchup.active_model.bounds
    end

    private

    def draw_preview_segment(view)
      return unless @start_point && @mouse_ip.valid?

      endpoint = solve_endpoint(@start_point, @mouse_ip.position)
      return unless endpoint

      view.line_width = 2
      view.drawing_color = Sketchup::Color.new(44, 123, 229, 255)
      view.draw(GL_LINES, @start_point, endpoint)
      view.draw_points([endpoint], 8, 1, Sketchup::Color.new(44, 123, 229, 255))
    end

    def draw_overlay(view)
      lines = overlay_lines
      return if lines.empty?

      ui = ui_scale
      pos = [@mouse_x + (OVERLAY_OFFSET_X * ui), @mouse_y + (OVERLAY_OFFSET_Y * ui)]
      ops = {
        color: Sketchup::Color.new(255, 255, 255),
        size: (FONT_SIZE * ui).round
      }

      metrics = overlay_bounds_px(view, pos, lines, ui)
      pad_x = (OVERLAY_PADDING_X * ui).round
      pad_y = (OVERLAY_PADDING_Y * ui).round

      bg_left = metrics[:left] - pad_x
      bg_top = metrics[:top] - pad_y
      bg_right = metrics[:right] + pad_x
      bg_bottom = metrics[:bottom] + pad_y

      box_height = bg_bottom - bg_top
      lift = box_height + (8 * ui).round
      bg_top -= lift
      bg_bottom -= lift
      pos[1] -= lift

      bg = Sketchup::Color.new(0, 0, 0, 150)
      bd = Sketchup::Color.new(255, 255, 255, 90)
      view.drawing_color = bg
      pts2d = [[bg_left, bg_top], [bg_right, bg_top], [bg_right, bg_bottom], [bg_left, bg_bottom]]
      begin
        view.draw2d(GL_QUADS, pts2d)
      rescue StandardError
        view.draw2d(GL_TRIANGLE_FAN, pts2d)
      end
      view.line_width = 1
      view.drawing_color = bd
      view.draw2d(GL_LINE_LOOP, pts2d)

      line_height = ((FONT_SIZE + 4) * ui).round
      lines.each_with_index do |line, i|
        p = [pos[0], pos[1] + (i * line_height)]
        view.draw_text(p, line, ops)
      end
    end

    def overlay_lines
      [
        "Slope: #{slope_percent_text} (#{slope_degrees_text})",
        "Axis lock: #{axis_lock_label}",
        'Enter slope as % or deg'
      ]
    end

    def slope_percent_text
      format('%<v>.2f%%', v: @slope_ratio * 100.0)
    end

    def slope_degrees_text
      deg = Math.atan(@slope_ratio) * 180.0 / Math::PI
      format('%<v>.2f°', v: deg)
    end

    def update_status_text
      mode = @start_point ? 'pick next point' : 'pick start point'
      Sketchup.status_text = "Slope Line: #{mode} | slope #{slope_percent_text} (#{slope_degrees_text}) | lock #{axis_lock_label}"
      update_vcb
    end

    def axis_lock_label
      case @axis_lock
      when :x then 'X'
      when :y then 'Y'
      else 'None'
      end
    end

    def update_vcb
      Sketchup.vcb_label = 'Slope'
      Sketchup.vcb_value = vcb_display_value
    rescue StandardError
      nil
    end

    def vcb_display_value
      case @slope_source
      when :degrees
        format('%<v>.2fdeg', v: @slope_source_value)
      else
        format('%<v>.2f%%', v: @slope_source_value)
      end
    end

    def parse_slope_input(text)
      return nil unless text

      raw = text.strip.downcase
      return nil if raw.empty?

      if raw.end_with?('%')
        num = Float(raw.delete_suffix('%').strip)
        return { ratio: num / 100.0, source: :percent, source_value: num }
      end

      if raw.end_with?('deg')
        num = Float(raw.delete_suffix('deg').strip)
        return degrees_to_ratio(num)
      end

      if raw.end_with?('d')
        num = Float(raw.delete_suffix('d').strip)
        return degrees_to_ratio(num)
      end

      # Default plain numbers to percent for quick input.
      num = Float(raw)
      { ratio: num / 100.0, source: :percent, source_value: num }
    rescue ArgumentError, TypeError
      nil
    end

    def degrees_to_ratio(num)
      return nil if num.abs >= MAX_ABS_DEGREES

      rad = num * Math::PI / 180.0
      { ratio: Math.tan(rad), source: :degrees, source_value: num }
    end

    def solve_endpoint(start_pt, target_pt)
      tx = target_pt.x
      ty = target_pt.y
      if @axis_lock == :x
        ty = start_pt.y
      elsif @axis_lock == :y
        tx = start_pt.x
      end

      dx = tx - start_pt.x
      dy = ty - start_pt.y
      horizontal = Math.sqrt((dx * dx) + (dy * dy))
      return nil if horizontal <= 1e-9

      dz = horizontal * @slope_ratio
      Geom::Point3d.new(tx, ty, start_pt.z + dz)
    end

    def cursor_id
      return @@cursor_slope_line_id if @@cursor_slope_line_id

      cursor_path = File.join(__dir__, 'UI', 'cursor_slope_line.svg')
      if File.exist?(cursor_path)
        # 32x32 cursor: hotspot at bottom-left.
        @@cursor_slope_line_id = UI.create_cursor(cursor_path, 0, 31)
      else
        @@cursor_slope_line_id = CURSOR_PENCIL
      end
      @@cursor_slope_line_id
    rescue StandardError
      @@cursor_slope_line_id = CURSOR_PENCIL
    end

    def ui_scale
      UI.respond_to?(:scale_factor) ? UI.scale_factor.to_f : 1.0
    end

    def overlay_bounds_px(view, pos, lines, ui)
      line_height = ((FONT_SIZE + 4) * ui).round
      max_width = lines.map { |line| text_width_px(view, line) }.max || 0
      {
        left: pos[0],
        top: pos[1],
        right: pos[0] + max_width,
        bottom: pos[1] + (line_height * lines.length)
      }
    end

    def text_width_px(view, text)
      if view.respond_to?(:text_width)
        view.text_width(text)
      else
        (text.length * scaled_font_size * 0.6).ceil
      end
    end

    def scaled_font_size
      if UI.respond_to?(:scale_factor)
        (FONT_SIZE * UI.scale_factor).round
      else
        FONT_SIZE
      end
    end
  end
end
