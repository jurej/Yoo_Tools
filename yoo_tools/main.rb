# frozen_string_literal: true

module Yoo_Tools
  EXTENSION_NAME = 'Slope Overlay'
  ALIGN_TOOL_NAME = 'Align to Axis (Coplanar)'
  DEBUG = true

  require_relative 'tool'
  require_relative 'align_tool'

  def self.activate_tool
    Sketchup.active_model.select_tool(Tool.new)
  end

  def self.activate_align_tool
    Sketchup.active_model.select_tool(AlignTool.new)
  end

  def self.deactivate_tool
    Sketchup.active_model.select_tool(nil)
  end

  def self.active?
    tool = Sketchup.active_model.tools.active_tool
    tool.is_a?(Tool)
  end

  def self.safe_call(context)
    yield
  rescue Exception => e # rubocop:disable Lint/RescueException
    log_debug("[Yoo_Tools] #{context} failed: #{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}")
    begin
      UI.messagebox("Yoo Tools error.\n\n#{e.class}: #{e.message}\n\nOpen Window → Ruby Console for details.")
    rescue StandardError
      nil
    end
  end

  def self.log_debug(message)
    return unless DEBUG

    begin
      puts(message)
    rescue StandardError
      nil
    end
  end

  unless file_loaded?(__FILE__)
    safe_call('menu registration') do
      plugins_menu = UI.menu('Plugins')
      plugins_menu.add_item(EXTENSION_NAME) do
        safe_call('toggle tool (Plugins menu)') do
          if active?
            deactivate_tool
          else
            activate_tool
          end
        end
      end
      plugins_menu.add_item(ALIGN_TOOL_NAME) do
        safe_call('Align tool (Plugins menu)') { activate_align_tool }
      end

      UI.add_context_menu_handler do |menu|
        yoo_menu = menu.add_submenu('Yoo_Tools')
        yoo_menu.add_item(EXTENSION_NAME) do
          safe_call('toggle tool (context menu)') do
            if active?
              deactivate_tool
            else
              activate_tool
            end
          end
        end
        yoo_menu.add_item(ALIGN_TOOL_NAME) do
          safe_call('Align tool (context menu)') { activate_align_tool }
        end
      end
    end

    file_loaded(__FILE__)
  end
end
