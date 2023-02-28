# https://github.com/bai-yi-bai/asciidoctor-pdf-list-of-figures
# Copyright (c) 2023 白一百
# 
# This is an AsciiDoctor-PDF extensions which creates a List of Figures (LoF) in the style of the Table of Contents (ToC)
# This includes the Figure Title, the dots, and page number.
#
# It is hoped that this extension can be built upon for use in creating a List of Table (LoT) and List of Examples (LoE).
#
# This code is licensed under the MIT license, please take it, use it, improve it, and help the AsciiDoctor community.
#
# 2023-02-28: This is not a "final" implementation.
#
# Alwinator built the asciidoctor-lists extension (https://github.com/Alwinator/asciidoctor-lists, 
# https://github.com/asciidoctor/asciidoctor-extensions-lab/issues/111), but it has a few drawbacks.
#
# This LoF has these features:
# - Provides a similar look-and-feel to the existing built-in ToC (it was built upon it).
# - The page number is displayed.
#
# Required development gems:
# - securerandom
# - byebug
#
# Known issues:
# - The Figure signifer, "Figure" is not printed.
# - The Figure counter, "Figure 1" is not printed.
# - The ability to add whitspace between the signifer, counter, and title would be nice
# - This extension only works with a specific Figure title syntax. It is unclear what syntax this is. 
#   This needs to be fixed. https://github.com/asciidoctor/asciidoctor/issues/858, 
#   https://docs.asciidoctor.org/asciidoc/latest/macros/xref-text-and-style/, https://docs.asciidoctor.org/asciidoc/latest/macros/images/
#
#   [[Title, Title]]
#   image::image_file.ext[title='Title']
#
# If the proper figure syntax is not used correctly, the page number is rendered as '?'.
#
# - This implementation re-uses the toc: default theme elements (.yml), separate theming/styling needs to be defined.
#   Currently the styling for toc-h3 is used.
#
# Some useful links:
#
# Documentation for writing (core) Asciidoctor extensions: 
# https://docs.asciidoctor.org/asciidoctor/latest/extensions/ (ruby)
# https://docs.asciidoctor.org/asciidoctorj/latest/extensions/ (java, more thorough than ruby documentation)
# https://docs.asciidoctor.org/asciidoctor.js/latest/extend/extensions/ (javascript, also more through than ruby documentation)
#
# Implementation of Converter in asciidoctor-pdf (which we are extending): 
# https://github.com/asciidoctor/asciidoctor-pdf/blob/ef9fc159feef6cd64e66978b9277f3b057fef77f/lib/asciidoctor/pdf/converter.rb#L2372
# 
# Asciidoctor PDF documentation on extending the converter (could use some more details):
# https://docs.asciidoctor.org/pdf-converter/latest/extend/
#

require 'asciidoctor'
require 'asciidoctor/extensions'
require 'securerandom'
require 'byebug'

# Macro processor that is activated when the lof::[] macro is used
# It creates an empty block with a context value of :lof, 
# which the PDF converter will render/"ink" in a particular way
class LOFContextMacroProcessor < ::Asciidoctor::Extensions::BlockMacroProcessor
  use_dsl
  named :lof

  def process(parent, target, attrs)
    puts "Activated lof::[] macro"
    block = create_block(parent, :lof, nil, {})
    block.content_model = :empty
    parent.append(block)
    nil
  end
end

# asciidoctor-pdf extension that attempts to reuse the TOC rendering logic to render the LOF
class PDFConverterWithLOF < Asciidoctor::Converter.for('pdf')
  register_for 'pdf'

  # I've added lots of this method overrides to help me debug the order of execution
  def convert_document(...)
    puts "convert_document"
    super
  end

  def convert_preamble node
    puts "convert_preamble"
    super
  end

  # Executed once for dry run and once for final output.
  def convert_toc(...)
    puts "convert_toc"
    super
  end

  # This method is called by metaprogramming in the converter because the LOF block has a context value of :lof
  def convert_lof(node, opts = {})
    puts "convert_lof"
    raise 'Unexpected: @lof_extent is nil' if @lof_extent.nil?
    puts "lof_extent is not nil"    
  end

  # Important note:
  #
  # In order to insert the LOF into the PDF, we need to first allocate some pages for it.
  # We need a hook at the appropriate point in the document conversion process to do this, 
  # which would be more or less at the same time as allocating space for the TOC.
  #
  # The TOC is allocated in a specific part of the convert_document method, which is a very long method full of precisely ordered side effects.
  # One approach would be to override convert_document, duplicate the existing impementation
  # and insert the LOF allocation call next to the TOC allocation call,
  # but this would be very brittle and would break the PDF converter if the Asciidoctor PDF codebase changes.
  #
  # Instead, we can use the allocate_toc mehtod as a hook, so we override it and call the allocate_lof method after the TOC allocation is done.
  def allocate_toc(doc, lof_num_levels, toc_start_cursor, break_after_toc)
    puts "allocate_toc"
    result = super
    @lof_extent = allocate_lof(doc, lof_num_levels, toc_start_cursor, break_after_toc)
    result
  end

  def traverse(node)
    puts "traversing node of type #{ node.node_name || node.class } with title #{ node.title }"
    super
  end

  # Important note:
  #
  # Following the same reasoning as for allocation, 
  # we need a good hook for rendering the LOF at the right point in the document rendering process, 
  # that doesn't require us to duplicate too much existing logic.
  # 
  # Here, we render the LOF as a side effect of rendering the TOC, when room has already been allocated for it.
  def ink_toc(doc, num_levels, toc_page_number, start_cursor, num_front_matter_pages = 0)
    puts "ink_toc"

    unless @lof_extent.nil?
      puts "Inking LOF"
      ink_lof(doc, num_levels, @lof_extent.from.page, @lof_extent.from.cursor, num_front_matter_pages)
    end

    super      
  end

  protected

  def get_entries_for_lof(node)
    puts "get_entries_for_lof"

    blocks = node.find_by(traverse_documents: true, context: :image) 
    raise('Could not find any images') if blocks.empty?
    # Default title should probably be injected via the attributes
    blocks.each { |b| b.title ||= 'missing title' }
    blocks
  end

  # This method is a copy of the allocate_toc method, with a brutish find and replace of toc with lof
  def allocate_lof(doc, lof_num_levels, lof_start_cursor, break_after_lof)
    puts "allocate_lof"
    
    lof_start_page_number = page_number
    to_page = nil
    extent = dry_run onto: self do
      to_page = ink_lof(doc, lof_num_levels, lof_start_page_number, lof_start_cursor).end
      theme_margin :block, :bottom unless break_after_lof
    end
    if to_page > extent.to.page
      extent.to.page = to_page
      extent.to.cursor = bounds.height
    end
    if break_after_lof
      extent.each_page { start_new_page }
    else
      extent.each_page {|first_page| start_new_page unless first_page }
      move_cursor_to extent.to.cursor
    end
    extent
  end


  # This method is a copy of the ink_toc method, with a partial find and replace of "toc" with "lof".
  #
  # Much of this logic seems to deal with styling and themes, 
  # and it will be a matter of preference how much should be inherited from the TOC styling.
  def ink_lof(doc, num_levels, lof_page_number, start_cursor, num_front_matter_pages = 0)
    puts "ink_lof"
    
    go_to_page lof_page_number unless (page_number == lof_page_number) || scratch?
    start_page_number = page_number
    move_cursor_to start_cursor
    unless (lof_title = doc.attr 'lof-title').nil_or_empty?
      theme_font_cascade [[:heading, level: 3], :lof_title] do
        lof_title_text_align = (@theme.lof_title_text_align || @theme.heading_h2_text_align || @theme.heading_text_align || @base_text_align).to_sym
        ink_general_heading doc, lof_title, align: lof_title_text_align, level: 3, outdent: true, role: :loftitle
      end
    end
    unless num_levels < 0
      dot_leader = theme_font :toc do
        if (dot_leader_font_style = @theme.toc_dot_leader_font_style&.to_sym || :normal) != font_style
          font_style dot_leader_font_style
        end
        font_size @theme.toc_dot_leader_font_size
        {
          font_color: @theme.toc_dot_leader_font_color || @font_color,
          font_style: dot_leader_font_style,
          font_size: font_size,
          levels: ((dot_leader_l = @theme.toc_dot_leader_levels) == 'none' ? ::Set.new :
              (dot_leader_l && dot_leader_l != 'all' ? dot_leader_l.to_s.split.map(&:to_i).to_set : (0..num_levels).to_set)),
          text: (dot_leader_text = @theme.toc_dot_leader_content || DotLeaderTextDefault),
          width: dot_leader_text.empty? ? 0 : (rendered_width_of_string dot_leader_text),
          spacer: { text: NoBreakSpace, size: (spacer_font_size = @font_size * 0.25) },
          spacer_width: (rendered_width_of_char NoBreakSpace, size: spacer_font_size),
        }
      end
      theme_margin :toc, :top
      ink_toc_level(get_entries_for_lof(doc), num_levels, dot_leader, num_front_matter_pages)
    end
    lof_page_numbers = (lof_page_number..(lof_page_number + (page_number - start_page_number)))
    go_to_page page_count unless scratch?
    lof_page_numbers
  end
end

# Register the extensions to asciidoctor
Asciidoctor::Extensions.register do
  block_macro LOFContextMacroProcessor
end
