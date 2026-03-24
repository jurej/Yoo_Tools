require 'sketchup.rb'
require 'extensions.rb'

module Yoo_Tools
  unless file_loaded?(__FILE__)
    extension = SketchupExtension.new('Yoo Tools', 'yoo_tools/main')
    extension.description = 'Several useful tools for SketchUp.'
    extension.version = '1.4.0'
    extension.creator = 'Jure Judez'
    extension.copyright = "Copyright (c) #{Time.now.year} Jure Judez"
    Sketchup.register_extension(extension, true)

    file_loaded(__FILE__)
  end
end

