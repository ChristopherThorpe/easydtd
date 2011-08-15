class EasyDTD
  attr_accessor :dtd, :parser, :elements

  def initialize(str)
    @dtd = if File === str
      str.read
    elsif File.exists?(str)
      File.open(str){|f| f.read}
    elsif URI::parse(str).host
      response = Net::HTTP.get_response(URI.parse(str))
      raise "Could not load DTD from #{str}" unless response.code.to_i == 200
      response.body
    else
      str
    end
    @parser     = EasyDTD::Parser.new(@dtd)
    @parsed_dtd = @parser.parse_dtd
    @elements   = Hash[@parsed_dtd.select{|e| EasyDTD::Parser::Element === e}.map{|e| [e.name, e]}]
  end

  # Please provide only one root 
  def write_xml(data, builder=Nokogiri::XML::Builder.new(:encoding => 'UTF-8'))
    raise "write_xml: only one root is permitted" unless data.try(:keys).try(:size) == 1
    write_xml_element(data.keys.first, data, builder)
  end

  def write_xml_element(name, data, builder)
    definition = elements[name].definition
    myself = self
    result = false
    builder.send(name) {
      result = myself.write_xml_element_definition(definition, data[name], builder)
    }
    result
  end

  def pattern_data_wrap(definition, data)
    if definition.definition.pattern.nil? && Hash === data
      name = definition.definition.definition
      data = Array.wrap(data[name]).map{ |d| {name, d} }
    end
    data
  end

  def handle_pattern(definition, data, builder)
    case definition.pattern
    when :ALTERNATION
      definition.definition.each do |dfn|
        return true if write_xml_element_definition(dfn, data, builder)
      end
      false
    when :CONCATENATION
      definition.definition.each do |dfn|
        return false unless write_xml_element_definition(dfn, data, builder)
      end
      true
    when :STAR
      return true if data.blank?
      pattern_data_wrap(definition, data).each do |e|
        return false unless write_xml_element_definition(definition.definition, e, builder)
      end
      true
    when :PLUS
      return false if data.blank?
      pattern_data_wrap(definition, data).each do |e|
        return false unless write_xml_element_definition(definition.definition, e, builder)
      end
      true
    when :QUESTION
      # TODO: error check
      write_xml_element_definition(definition.definition, data, builder)
      return true
    else
      raise "Unexpected pattern #{definition.pattern}"
    end
  end

  def write_xml_element_definition(definition, data, builder)
    status = if definition.respond_to?(:pattern) && !definition.pattern.nil?
      handle_pattern(definition, data, builder)
    else
      case definition
      when :EMPTY
        # check that the data match
        raise "Expected EMPTY data; got #{data.inspect}" unless data.blank? || data == true
      when :'#PCDATA'
        builder << data.to_s
        true
      when Symbol
        if Hash === data && data.include?(definition)
          write_xml_element(definition, data, builder)
        else
          false # data do not support this alternate
        end
      when EasyDTD::Parser::Element::Def
        write_xml_element_definition(definition.definition, data, builder)
      end
    end
    status
  end
end

class EasyDTD::Parser
  attr_accessor :dtd

  @def_str = nil
  def initialize(str)
    @dtd = str
  end

  def parse_dtd
    str = @dtd
    str.strip!
    dtd = []
    while !str.empty?
      matches = str.match(/<!(--|ELEMENT|ENTITY|ATTLIST)\s*(.*?)>(.*)/mu)
      raise "Invalid DTD at #{str[0,20]}" unless !matches.nil? && matches.size > 1
      dtd.push case matches[1] 
      when 'ENTITY' 
        (name, desc) = matches[2].split(/\s/, 2)
        raise 'ENTITY not supported'
        EasyDTD::Parser::Entity.new(name, desc)
      when 'ELEMENT' 
        (name, desc) = matches[2].split(/\s/, 2)
        desc.strip!
        @def_str = desc
        EasyDTD::Parser::Element.new(name, parse_element_def)
      when 'ATTLIST' 
        raise 'ATTLIST not supported'
      when '--' # comment
        EasyDTD::Parser::Comment.new(matches[2].sub(/--$/, ''))
      end
      str = matches[3]
      str.strip!
    end
    dtd
  end
  
  private
  TERMINAL_RE = '(?:#PCDATA|[A-Z0-9_]+)'
  def terminal?(lex)
    lex =~ /^(#{TERMINAL_RE})/
  end
  
  def parse_element_def
    (lex, @def_str) = get_lexeme(@def_str)
    if lex == '('
      element_def = parse_element_def
      (lex, @def_str) = get_lexeme(@def_str)
      raise "Missing ) at #{lex + @def_str}" unless lex == ')'
    elsif terminal?(lex)
      element_def = EasyDTD::Parser::Element::Def.new(lex.to_sym)
    else
      raise "Unknown string in element_def: #{lex}"
    end

    (lex, @def_str) = get_lexeme(@def_str)
    while lex
      case lex 
      when ','
        element_def = element_def.concatenate(parse_element_def)
      when '|'
        element_def = element_def.alternate(parse_element_def)
      when '*'
        element_def = element_def.star
      when '+'
        element_def = element_def.plus
      when '?'
        element_def = element_def.question
      else
        @def_str = lex + @def_str # putback
        break
      end
      (lex, @def_str) = get_lexeme(@def_str)
    end
    element_def
  end

  def get_lexeme(data)
    return [nil,''] if data.blank?
    data.strip!
    if data.match(/^([(),|?*+])(.*)$/)
      [$1, $2]
    elsif data.match(/^(#{TERMINAL_RE})(.*)$/)
      [$1, $2]
    else
      raise "Unknown string '#{data}'"
    end
  end
end

class EasyDTD::Parser::Comment
  attr_accessor :comment
  def initialize(data)
    @comment = data
  end
end

class EasyDTD::Parser::AttList
end

class EasyDTD::Parser::Entity
  attr_accessor :name, :definition
  def initialize(name, data)
    data.strip!
    raise 'invalid ENTITY description' unless data =~ /^"(.*)"$/
    @name       = name
    @definition = data
  end
end

class EasyDTD::Parser::Element
  attr_accessor :name, :definition

  def initialize(name, definition)
    @name = name.try(:to_sym)
    raise "Expected EasyDTD::Parser::Element::Def; got #{definition.inspect}" unless EasyDTD::Parser::Element::Def === definition
    @definition = definition
  end

end

class EasyDTD::Parser::Element::Def
  attr_accessor :definition, :pattern

  def initialize(defn, pattern=nil)
    @definition = defn
    @pattern    = pattern
  end

  def required?
    @pattern != :STAR && @pattern != :QUESTION
  end

  def multiple?
    @pattern == :STAR || @pattern == :PLUS
  end

  def star
    self.class.new(self, :STAR)
  end

  def plus
    self.class.new(self, :PLUS)
  end

  def question
    self.class.new(self, :QUESTION)
  end

  def conalternate(defn, type)
    if defn.pattern == type && self.pattern == type
      definition += defn.definition
      self
    elsif pattern == type
      definition += [defn]
      self
    elsif defn.pattern == type
      self.class.new([self] + defn.definition, type)
    else
      self.class.new([self, defn], type)
    end
  end
  def alternate(defn)
    conalternate(defn, :ALTERNATION)
  end
  def concatenate(defn)
    conalternate(defn, :CONCATENATION)
  end
end
