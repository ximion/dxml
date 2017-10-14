// Written in the D programming language

/++
    Copyright: Copyright 2017
    License:   $(WEB www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
    Author:   Jonathan M Davis
  +/
module dxml.reader.parser;

import std.algorithm : startsWith;
import std.range.primitives;
import std.range : takeExactly;
import std.traits;
import std.typecons : Flag, Nullable, nullable;

import dxml.reader.internal;

/++
    The exception type thrown when the XML parser runs into invalid XML.
  +/
class XMLParsingException : Exception
{
    /++
        The position in the XML input where the problem is.

        How informative it is depends on the $(D PositionType) used when parsing
        the XML.
      +/
    SourcePos pos;

package:

    this(string msg, SourcePos sourcePos, string file = __FILE__, size_t line = __LINE__)
    {
        pos = sourcePos;
        super(msg, file, line);
    }
}


/++
    Where in the XML text an $(D Entity) is. If the $(D PositionType) when
    parsing does not keep track of a given field, then that field will always be
    $(D -1).
  +/
struct SourcePos
{
    /// A line number in the XML file.
    int line = -1;

    /++
        A column number in a line of the XML file.

        Each code unit is considered a column, so depending on what a program
        is looking to do with the column number, it may need to examine the
        actual text on that line and calculate the number that represents
        what the program wants to display (e.g. the number of graphemes).
      +/
    int col = -1;
}


/++
    At what level of granularity the position in the XML file should be kept
    track of (be it for error reporting or any other use the application might
    have for that information). $(D none) is the most efficient but least
    informative, whereas $(D lineAndCol) is the most informative but least
    efficient.
  +/
enum PositionType
{
    /// Both the line number and the column number are kept track of.
    lineAndCol,

    /// The line number is kept track of but not the column.
    line,

    /// The position is not tracked.
    none,
}


/// Flag for use with Config.
alias SkipComments = Flag!"SkipComments";

/// Flag for use with Config.
alias SkipDTD = Flag!"SkipDTD";

/// Flag for use with Config.
alias SkipProlog = Flag!"SkipProlog";

/// Flag for use with Config.
alias SplitEmpty = Flag!"SplitEmpty";


/++
    Used to configure how the parser works.
  +/
struct Config
{
    /++
        Whether the comments should be skipped while parsing.

        If $(D true), any $(D Entity)s of type $(D EntityType.comment) will be
        omitted from the parsing results.
      +/
    auto skipComments = SkipComments.no;

    /++
        Whether the DOCTYPE entities should be skipped while parsing.

        If $(D true), any $(D Entity)s of type $(D EntityType.dtdStartTag) and
        $(D EntityType.dtdEndTag) and any entities in between will be omitted
        from the parsing results.
      +/
    auto skipDTD = SkipDTD.no;

    /++
        Whether the prolog should be skipped while parsing.

        If $(D true), any $(D Entity)s prior to the root element will omitted
        from the parsing results.
      +/
    auto skipProlog = SkipProlog.no;

    /++
        Whether the parser should report empty element tags as if they were a
        start tag followed by an end tag with nothing in between.

        If $(D true), then whenever an $(D EntityType.elementEmpty) is
        encountered, the parser will claim that that entity is an
        $(D EntityType.elementStart), and then it will provide an
        $(D EntityType.elementEnd) as the next entity before the entity that
        actually follows it.

        The purpose of this is to simplify the code using the parser, since most
        code does not care about the difference between an empty tag and a start
        and end tag with nothing in between. But since some code will care about
        the difference, the behavior is configurable rather than simply always
        treating them as the same.
      +/
    auto splitEmpty = SplitEmpty.no;

    ///
    PositionType posType = PositionType.lineAndCol;
}


/++
    Helper function for creating a custom config. It makes it easy to set one
    or more of the member variables to something other than the default without
    having to worry about explicitly setting them individually or setting them
    all at once via a constructor.

    The order of the arguments does not matter. The types of each of the members
    of Config are unique, so that information alone is sufficient to determine
    which argument should be assigned to which member.
  +/
Config makeConfig(Args...)(Args args)
{
    Config config;

    foreach(arg; args)
    {
        foreach(memberName; __traits(allMembers, Config))
        {
            static if(is(typeof(__traits(getMember, config, memberName)) == typeof(arg)))
                mixin("config." ~ memberName ~ " = arg;");
        }
    }

    return config;
}

///
@safe pure nothrow @nogc unittest
{
    {
        auto config = makeConfig(SkipComments.yes);
        assert(config.skipComments == SkipComments.yes);
        assert(config.skipDTD == Config.init.skipDTD);
        assert(config.skipProlog == Config.init.skipProlog);
        assert(config.splitEmpty == Config.init.splitEmpty);
        assert(config.posType == Config.init.posType);
    }

    {
        auto config = makeConfig(SkipComments.yes, PositionType.none);
        assert(config.skipComments == SkipComments.yes);
        assert(config.skipDTD == Config.init.skipDTD);
        assert(config.skipProlog == Config.init.skipProlog);
        assert(config.splitEmpty == Config.init.splitEmpty);
        assert(config.posType == PositionType.none);
    }

    {
        auto config = makeConfig(SplitEmpty.yes, SkipComments.yes, PositionType.line);
        assert(config.skipComments == SkipComments.yes);
        assert(config.skipDTD == Config.init.skipDTD);
        assert(config.skipProlog == Config.init.skipProlog);
        assert(config.splitEmpty == SplitEmpty.yes);
        assert(config.posType == PositionType.line);
    }
}


/++
    This config is intended for making it easy to parse XML that does not
    contain some of the more advanced XML features such as DTDs. It skips
    everything that can be configured to skip.
  +/
enum simpleXML = makeConfig(SkipComments.yes, SkipDTD.yes, SkipProlog.yes, SplitEmpty.yes, PositionType.lineAndCol);

///
@safe pure nothrow @nogc unittest
{
    static assert(simpleXML.skipComments == SkipComments.yes);
    static assert(simpleXML.skipDTD == SkipDTD.yes);
    static assert(simpleXML.skipProlog == SkipProlog.yes);
    static assert(simpleXML.splitEmpty == SplitEmpty.yes);
    static assert(simpleXML.posType == PositionType.lineAndCol);
}


/++
    Represents the type of an XML entity. Used by EntityParser.
  +/
enum EntityType
{
    /// The $(D <!ATTLIST .. >) tag.
    attlistDecl,

    /// A cdata section: $(D <![CDATA[ ... ]]>).
    cdata,

    /// An XML comment: $(D <!-- ... -->).
    comment,

    /// The beginning of a $(D <!DOCTYPE .. >) tag.
    docTypeStart,

    /// The $(D >) indicating the end of a $(D <!DOCTYPE) tag.
    docTypeEnd,

    /// The $(D <!ELEMENT .. >) tag.
    elementDecl,

    /// The start tag for an element. e.g. $(D <foo name="value">).
    elementStart,

    /// The end tag for an element. e.g. $(D </foo>).
    elementEnd,

    /// The tag for an element with no contents. e.g. $(D <foo name="value"/>).
    elementEmpty,

    /// The $(D <!ENTITY .. >) tag.
    entityDecl,

    /// The $(D <!NOTATION .. >) tag.
    notationDecl,

    /++
        A processing instruction such as <?foo?>. Note that $(D <?xml ... ?>) is
        an $(D xmlDecl) and not a processingInstruction.
      +/
    processingInstruction,

    /++
        The content of an element tag that is simple text.

        If there is an entity other than the end tag following the text, then
        the text includes up to that entity.
      +/
    text,

    /++
        The $(D <?xml ... ?>) entity that can start an XML 1.0 document and must
        start an XML 1.1 document.
      +/
    xmlDecl
}


/++
    Lazily parses the given XML.

    The resulting EntityParser is similar to an input range with how it's
    iterated until it's consumed, and its state cannot be saved (since
    unfortunately, saving it would require allocating additional memory), but
    because there are essentially multiple ways to pop the front (e.g. choosing
    to skip all of contents between a start tag and end tag), the input range
    API didn't seem to appropriate, even if the result functions similarly.

    Also, unlike a range the, "front" is integrated into the EntityParser rather
    than being a value that can be extracted. So, while an entity can be queried
    while it is the "front", it can't be kept around after the EntityParser has
    moved to the next entity. Only the information that has been queried for
    that entity can be retained (e.g. its name, attributes, or textual value).
    While that does place some restrictions on how an algorithm operating on an
    EntityParser can operate, it does allow for more efficient processing.

    A range wrapper for an EntityParser could definitely be written, but it
    would be less efficient and less flexible, and if something like that is
    really needed, it may make more sense to simply use dxml.reader.dom. Some
    of the aspects of XML's design simply make it difficult to avoid allocating
    for each entity if an entity is treated as an element that can be returned
    by front and retained after a call to popFront.

    If invalid XML is encountered at any point during the parsing process, an
    $(D XMLParsingException) will be thrown.

    However, note that EntityParser does not care about XML validation beyond
    what is required to correctly parse what has been asked to parse. For
    instance, any portions that are skipped (either due to the values in the
    Config or because a function such as skipContents is called) will only be
    validated enough to correctly determine where those portions terminated.
    Similarly, if the functions to process the value of an entity are not
    called (e.g. $(D attributes) for $(D EntityType.elementStart) and
    $(D xmlSpec) for $(D EntityType.xmlSpec)), then those portions of the XML
    will not be validated beyond what is required to iterate to the next entity.

    A possible enhancement would be to add a validateXML function that
    corresponds to parseXML and fully validates the XML, but for now, no such
    function exists.

    EntityParser is a reference type.
  +/
EntityParser!(config, R) parseXML(Config config = Config.init, R)(R xmlText)
    if(isForwardRange!R && isSomeChar!(ElementType!R))
{
    return EntityParser!(config, R)(xmlText);
}

/// Ditto
struct EntityParser(Config cfg, R)
    if(isForwardRange!R && isSomeChar!(ElementType!R))
{
public:

    import std.algorithm : canFind;
    import std.range : only;

    private enum compileInTests = is(R == EntityCompileTests);

    ///
    static if(compileInTests) unittest
    {
        enum xml = "<?xml version='1.0'?>\n" ~
                   "<foo attr='42'>\n" ~
                   "    <bar/>\n" ~
                   "    <!-- no comment -->\n" ~
                   "    <baz hello='world'>\n" ~
                   "    nothing to say.\n" ~
                   "    nothing at all...\n" ~
                   "    </baz>\n" ~
                   "</foo>";

        {
            auto parser = parseXML(xml);
            assert(!parser.empty);
            assert(parser.type == EntityType.xmlDecl);

            auto xmlDecl = parser.xmlDecl;
            assert(xmlDecl.xmlVersion == "1.0");
            assert(xmlDecl.encoding.isNull);
            assert(xmlDecl.standalone.isNull);
        }

        {
            auto parser = parseXML!simpleXML(xml);
        }
    }


    /// The Config used for this parser.
    alias config = cfg;

    /++
        The type used when any slice of the original text is used. If $(D R)
        is a string or supports slicing, then SliceOfR is the same as $(D R);
        otherwise, it's the result of calling $(D takeExactly) on the text.
      +/
    static if(isDynamicArray!R || hasSlicing!R)
        alias SliceOfR = R;
    else
        alias SliceOfR = typeof(takeExactly(R.init, 42));

    // TODO re-enable these. Whenever EntityParser doesn't compile correctly due
    // to a change, these static assertions fail, and the actual errors are masked.
    // So, rather than continuing to deal with that whenever I change somethnig,
    // I'm leaving these commented out for now.
    /+
    ///
    static if(compileInTests) @safe unittest
    {
        import std.algorithm : filter;
        import std.range : takeExactly;

        static assert(is(EntityParser!(Config.init, string).SliceOfR == string));

        auto range = filter!(a => true)("some xml");

        static assert(is(EntityParser!(Config.init, typeof(range)).SliceOfR ==
                         typeof(takeExactly(range, 4))));
    }
    +/

    /++
        The type of the current entity.

        The value of this member determines which member functions and
        properties are allowed to be called, since some are only appropriate
        for specific entity types (e.g. $(D attributes) would not be appropriate
        for $(D EntityType.elementEnd)).
      +/
    @property EntityType type()
    {
        return _state.type;
    }

    /++
        The position of the current entity in the XML document.

        How accurate the position is depends on the parser configuration that's
        used.
      +/
    @property SourcePos pos()
    {
        return _state.pos;
    }

    /++
        Move to the next entity.

        The next entity is the next one that is linearly in the XML document.
        So, if the current entity has child entities, the next entity will be
        the child entity, whereas if it has no child entities, it will be the
        next entity at the same level.
      +/
    void next()
    {
        assert(0);
    }

    /++
        $(D true) if there is no more XML to process. It as en error to call
        $(D next) once $(D empty) is $(D true).
      +/
    bool empty()
    {
        return _state.grammarPos == GrammarPos.documentEnd;
    }

    /++
        Gives the name of the current entity.

        Note that this is the direct name in the XML for this entity and does
        not contain any of the names of any of the parent entities that this
        entity has.

        $(TABLE,
          $(TR $(TH Supported $(D EntityType)s)),
          $(TR $(TD $(D EntityType.docTypeStart))),
          $(TR $(TD $(D EntityType.elementStart))),
          $(TR $(TD $(D EntityType.elementEnd))),
          $(TR $(TD $(D EntityType.elementEmpty))),
          $(TR $(TD $(D EntityType.processingInstruction))))
      +/
    @property SliceOfR name()
    {
        with(EntityType)
            assert(only(docTypeStart, elementStart, elementEnd, elementEmpty, processingInstruction).canFind(type));

        assert(0);
    }

    /++
        Returns a range of attributes for a start tag where each attribute is
        represented as a $(D Tuple!(SliceOfR, "name", SliceOfR, "value")).

        $(TABLE,
          $(TR $(TH Supported $(D EntityType)s)),
          $(TR $(TD $(D EntityType.elementStart))))
          $(TR $(TD $(D EntityType.elementEmpty))))
      +/
    @property auto attributes()
    {
        with(EntityType)
            assert(only(elementStart, elementEmpty).canFind(type));

        import std.typecons : Tuple;
        alias Attribute = Tuple!(SliceOfR, "name", SliceOfR, "value");
        assert(0);
    }

    /++
        Returns the value of the current entity.

        In the case of $(D EntityType.processingInstruction), this is the text
        that follows the name.

        $(TABLE,
          $(TR $(TH Supported $(D EntityType)s)),
          $(TR $(TD $(D EntityType.cdata))),
          $(TR $(TD $(D EntityType.comment))),
          $(TR $(TD $(D EntityType.processingInstruction))),
          $(TR $(TD $(D EntityType.text))))
      +/
    @property SliceOfR text()
    {
        with(EntityType)
            assert(only(cdata, comment, processingInstruction, text).canFind(type));

        assert(0);
    }

    /++
        When at a start tag, moves the parser to the entity after the
        corresponding end tag tag and returns the contents between the two tags
        as text, leaving any markup in between as unprocessed text.

        $(TABLE,
          $(TR $(TH Supported $(D EntityType)s)),
          $(TR $(TD $(D EntityType.elementStart))))
      +/
    @property SliceOfR contentAsText()
    {
        with(EntityType)
            assert(type == elementStart);

        assert(0);
    }

    /++
        When at a start tag, moves the parser to the entity after the
        corresponding end tag.

        $(TABLE,
          $(TR $(TH Supported $(D EntityType)s)),
          $(TR $(TD $(D EntityType.elementStart))))
      +/
    void skipContents()
    {
        with(EntityType)
            assert(type == elementStart);

        assert(0);
    }

    /++
        Returns the $(D XMLDecl) corresponding to the current entity.

        $(TABLE,
          $(TR $(TH Supported $(D EntityType)s)),
          $(TR $(TD $(D EntityType.xmlDecl))))
      +/
    @property XMLDecl!R xmlDecl()
    {
        assert(type == EntityType.xmlDecl);

        import std.ascii : isDigit;

        void throwXPE(string msg, size_t line = __LINE__)
        {
            throw new XMLParsingException(msg, _state.currText.pos, __FILE__, line);
        }

        XMLDecl!R retval;

        // XMLDecl      ::= '<?xml' VersionInfo EncodingDecl? SDDecl? S? '?>'
        // VersionInfo  ::= S 'version' Eq ("'" versionNum "'" | '"' VersionNum '"')
        // Eq           ::= S? '=' S?
        // VersionNum   ::= '1.' [0-9]+
        // EncodingDecl ::= S 'encoding' Eq ('"' EncName '"' | "'" EncName "'" )
        // EncName      ::= [A-Za-z] ([A-Za-z0-9._] | '-')*
        // SDDecl       ::= S 'standalone' Eq (("'" ('yes' | 'no') "'") | ('"' ('yes' | 'no') '"'))

        // The '<?xml' and '?>' were already stripped off before _state.currText
        // was set.

        if(!stripWS(&_state.currText))
            throwXPE("There must be whitespace after <?xml");

        if(!stripStartsWith(&_state.currText, "version"))
            throwXPE("version missing after <?xml");
        stripEq(&_state.currText);

        {
            auto temp = takeEnquotedText(&_state.currText);
            retval.xmlVersion = stripBCU(temp.save);
            if(temp.length != 3)
                throwXPE("Invalid or unsupported XML version number");
            if(temp.front != '1')
                throwXPE("Invalid or unsupported XML version number");
            temp.popFront();
            if(temp.front != '.')
                throwXPE("Invalid or unsupported XML version number");
            temp.popFront();
            if(!isDigit(temp.front))
                throwXPE("Invalid or unsupported XML version number");
        }

        auto wasSpace = stripWS(&_state.currText);
        if(_state.currText.input.empty)
            return retval;

        if(_state.currText.input.front == 'e')
        {
            if(!wasSpace)
                throwXPE("There must be whitespace before the encoding declaration");
            popFrontAndIncCol(&_state.currText);
            if(!stripStartsWith(&_state.currText, "ncoding"))
                throwXPE("Invalid <?xml .. ?> declaration in prolog");
            stripEq(&_state.currText);
            retval.encoding = nullable(stripBCU(takeEnquotedText(&_state.currText)));

            wasSpace = stripWS(&_state.currText);
            if(_state.currText.input.empty)
                return retval;
        }

        if(_state.currText.input.front == 's')
        {
            if(!wasSpace)
                throwXPE("There must be whitespace before the standalone declaration");
            popFrontAndIncCol(&_state.currText);
            if(!stripStartsWith(&_state.currText, "tandalone"))
                throwXPE("Invalid <?xml .. ?> declaration in prolog");
            stripEq(&_state.currText);

            auto pos = _state.currText.pos;
            auto standalone = takeEnquotedText(&_state.currText);
            if(standalone.save.equalCU("yes"))
                retval.standalone = nullable(true);
            else if(standalone.equalCU("no"))
                retval.standalone = nullable(false);
            else
                throw new XMLParsingException("If standalone is present, its value must be yes or no", pos);
            stripWS(&_state.currText);
            checkNotEmpty(&_state.currText);
        }

        if(!_state.currText.input.empty)
            throwXPE("Invalid <?xml .. ?> declaration in prolog");

        return retval;
    }

private:

    // Parse at GrammarPos.prologMisc1.
    void _parseAtMisc1()
    {
        void throwXPE(string msg, size_t line = __LINE__)
        {
            throw new XMLParsingException(msg, _state.pos, __FILE__, line);
        }

        // document ::= prolog element Misc*
        // prolog   ::= XMLDecl? Misc* (doctypedecl Misc*)?
        // Misc ::= Comment | PI | S

        stripWS(_state);
        checkNotEmpty(_state);
        if(_state.input.front != '<')
            throwXPE("Expected <");
        popFrontAndIncCol(_state);
        checkNotEmpty(_state);

        switch(_state.input.front)
        {
            // Comment or doctypedecl
            case '!':
            {
            }
            // PI
            case '?':
            {
                popFrontAndIncCol(_state);
                _state.currText.pos = _state.pos;
                _state.currText.input = _state.takeUntil!"?>"();
                checkNotEmpty(_state);
                break;
            }
            // element
            default:
            {
                _state.grammarPos = GrammarPos.element;
                _parseAtElement(_state);
                break;
            }
        }
        // <!-- comment
        // <?  PI
        // <!DOCTYPE
        // < element
    }


    // Parse at GrammarPos.element.
    void _parseAtElement(PS)(PS state)
    {
    }


    this(R xmlText)
    {
        _state = new ParserState!(config, R)(xmlText);

        if(_state.stripStartsWith("<?xml"))
        {
            _state.currText.pos = _state.pos;
            _state.currText.input = _state.takeUntil!"?>"();
            _state.type = EntityType.xmlDecl;
            _state.grammarPos = GrammarPos.prologMisc1;
        }
        else
            _parseAtMisc1();
    }

    ParserState!(config, R)* _state;
}

// This is purely to provide a way to trigger the unittest blocks in Entity
// without compiling them in normally.
private struct EntityCompileTests
{
    @property bool empty() { assert(0); }
    @property char front() { assert(0); }
    void popFront() { assert(0); }
    @property typeof(this) save() { assert(0); }
}

@safe pure nothrow @nogc unittest
{
    EntityParser!(Config.init, EntityCompileTests) foo;
}


/++
    Information parsed from a <?xml ... ?> declaration.

    Note that while XML 1.1 requires this declaration, it's optional in XML
    1.0.
  +/
struct XMLDecl(R)
{
    import std.typecons : Nullable;

    /++
        The type used when any slice of the original text is used. If $(D R)
        is a string or supports slicing, then SliceOfR is the same as $(D R);
        otherwise, it's the result of calling $(D takeExactly) on the text.
      +/
    static if(isDynamicArray!R || hasSlicing!R)
        alias SliceOfR = R;
    else
        alias SliceOfR = typeof(takeExactly(R.init, 42));

    /++
        The version of XML that the document contains.
      +/
    SliceOfR xmlVersion;

    /++
        The encoding of the text in the XML document.

        Note that dxml only supports UTF-8, UTF-16, and UTF-32, and it is
        assumed that the encoding matches the character type. The parser
        ignores this field aside from providing its value as part of an XMLDecl.

        And as the current XML spec points out, including the encoding as part
        of the XML itself doesn't really work anyway, because you have to know
        the encoding before you can read the text. One possible enhancement
        would be to provide a function specifically for parsing the XML
        declaration and attempting to determine the encoding in the process
        (which the spec discusses), in which case, the caller could then use
        that information to convert the text to UTF-8, UTF-16, or UTF-32 before
        passing it to $(D parseXML), but dxml does not currently have such a
        function.
      +/
    Nullable!SliceOfR encoding;

    /++
        $(D true) if the XML document does $(I not) contain any external
        references. $(D false) if it does or may contain external references.
        It's null if the $(D "standalone") declaration was not included in the
        <?xml declaration.
      +/
    Nullable!bool standalone;
}


//------------------------------------------------------------------------------
// Private Section
//------------------------------------------------------------------------------
private:


struct ParserState(Config cfg, R)
{
    alias config = cfg;

    EntityType type;

    GrammarPos grammarPos;

    static if(config.posType == PositionType.lineAndCol)
        auto pos = SourcePos(1, 1);
    else static if(config.posType == PositionType.line)
        auto pos = SourcePos(1, -1);
    else
        SourcePos pos;

    typeof(byCodeUnit(R.init)) input;

    // This mirrors the ParserState's fields so that the same parsing functions
    // can be used to parse main text contained directly in the ParserState
    // and the currently saved text (e.g. for the attributes of a start tag).
    struct CurrText
    {
        alias config = cfg;
        typeof(takeExactly(byCodeUnit(R.init), 42)) input;
        SourcePos pos;
    }

    CurrText currText;

    this(R xmlText)
    {
        input = byCodeUnit(xmlText);
    }
}


version(unittest) auto testParser(Config config, R)(R xmlText) @trusted pure nothrow @nogc
{
    static getPS(R xmlText) @trusted nothrow @nogc
    {
        static ParserState!(config, R) ps;
        ps = ParserState!(config, R)(xmlText);
        return &ps;
    }
    alias FuncType = @trusted pure nothrow @nogc ParserState!(config, R)* function(R);
    return (cast(FuncType)&getPS)(xmlText);
}


// Used to indicate where in the grammar we're currently parsing.
enum GrammarPos
{
    // document ::= prolog element Misc*
    // prolog   ::= XMLDecl? Misc* (doctypedecl Misc*)?
    // This is that first Misc*. The next entity to parse is either a Misc, the
    // doctypedecl, or the root element which follows the prolog.
    prologMisc1,

    // document ::= prolog element Misc*
    // prolog   ::= XMLDecl? Misc* (doctypedecl Misc*)
    // This is that second Misc*. The next entity to parse is either a Misc or
    // the root element which follows the prolog.
    prologMisc2,

    // doctypedecl ::= '<!DOCTYPE' S Name (S ExternalID)? S? ('[' intSubset ']' S?)? '>'
    // intSubset   ::= (markupdecl | DeclSep)*
    // This is the intSubset such that the next thing to parse is a markupdecl,
    // DeclSep, or the ']' that follows the intSubset.
    intSubset,

    // document ::= prolog element Misc*
    // element  ::= EmptyElemTag | STag content ETag
    // This at the element. The next thing to parse will either be an
    // EmptyElemTag or STag.
    element,

    // element  ::= EmptyElemTag | STag content ETag
    // content ::= CharData? ((element | Reference | CDSect | PI | Comment) CharData?)*
    // This is at the content. The next thing to parse will be a CharData,
    // element, Reference, CDSect, PI, Comment, or ETag.
    contentStart,

    // element  ::= EmptyElemTag | STag content ETag
    // content ::= CharData? ((element | Reference | CDSect | PI | Comment) CharData?)*
    // This is after the first CharData?. The next thing to parse will be a
    // element, Reference, CDSect, PI, Comment, or ETag.
    contentMid,

    // element  ::= EmptyElemTag | STag content ETag
    // content ::= CharData? ((element | Reference | CDSect | PI | Comment) CharData?)*
    // This is after at the second CharData?. The next thing to parse will be a
    // CharData, element, Reference, CDSect, PI, Comment, or ETag.
    contentEnd,

    // document ::= prolog element Misc*
    // This is the Misc* at the end of the document. The next thing to parse is
    // either another Misc, or we will hit the end of the document.
    endMisc,

    // The end of the document (and the grammar) has been reached.
    documentEnd
}


// Similar to startsWith except that it consumes the part of the range that
// matches. It also deals with incrementing state.pos.col.
//
// It is assumed that there are no newlines.
bool stripStartsWith(PS)(PS state, string text)
{
    static assert(isPointer!PS, "_state.currText was probably passed rather than &_state.currText");

    alias R = typeof(PS.input);

    static if(hasLength!R)
    {
        if(state.input.length < text.length)
            return false;

        // This branch is separate so that we can take advantage of whatever
        // speed boost comes from comparing strings directly rather than
        // comparing individual characters.
        static if(isWrappedString!R && is(Unqual!(ElementType!R) == char))
        {
            if(state.input.source[0 .. text.length] != text)
                return false;
            state.input.popFrontN(text.length);
        }
        else
        {
            foreach(c; text)
            {
                if(state.input.front != c)
                    return false;
                state.input.popFront();
            }
        }
    }
    else
    {
        foreach(c; text)
        {
            if(state.input.empty)
                return false;
            if(state.input.front != c)
                return false;
            state.input.popFront();
        }
    }

    static if(state.config.posType == PositionType.lineAndCol)
        state.pos.col += text.length;

    return true;
}

@safe pure unittest
{
    import std.algorithm : equal;
    import std.meta : AliasSeq;
    import std.typecons : tuple;

    enum origHaystack = "hello world";
    enum needle = "hello";
    enum remainder = " world";

    foreach(func; testRangeFuncs)
    {
        auto haystack = func(origHaystack);

        foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, needle.length + 1)),
                             tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                             tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
        {
            auto state = testParser!(t[0])(haystack.save);
            assert(state.stripStartsWith(needle));
            assert(equalCU(state.input, remainder));
            assert(state.pos == t[1]);
        }

        foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, origHaystack.length + 1)),
                             tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                             tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
        {
            auto state = testParser!(t[0])(haystack.save);
            assert(state.stripStartsWith(origHaystack));
            assert(state.input.empty);
            assert(state.pos == t[1]);
        }

        foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 1)),
                             tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                             tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
        {
            {
                auto state = testParser!(t[0])(haystack.save);
                assert(!state.stripStartsWith("foo"));
                assert(state.pos == t[1]);
            }
            {
                auto state = testParser!(t[0])(haystack.save);
                assert(!state.stripStartsWith("hello sally"));
                assert(state.pos == t[1]);
            }
            {
                auto state = testParser!(t[0])(haystack.save);
                assert(!state.stripStartsWith("hello world "));
                assert(state.pos == t[1]);
            }
        }
    }
}


// Strips whitespace while dealing with state.pos accordingly. Newlines are not
// ignored.
// Returns whether any whitespace was stripped.
bool stripWS(PS)(PS state)
{
    static assert(isPointer!PS, "_state.currText was probably passed rather than &_state.currText");

    alias R = typeof(PS.input);
    enum hasLengthAndCol = hasLength!R && PS.config.posType == PositionType.lineAndCol;

    bool strippedSpace = false;

    static if(hasLengthAndCol)
        size_t lineStart = state.input.length;

    loop: while(!state.input.empty)
    {
        switch(state.input.front)
        {
            case ' ':
            case '\t':
            case '\r':
            {
                strippedSpace = true;
                state.input.popFront();
                static if(!hasLength!R)
                    nextCol!(PS.config)(state.pos);
                break;
            }
            case '\n':
            {
                strippedSpace = true;
                state.input.popFront();
                static if(hasLengthAndCol)
                    lineStart = state.input.length;
                nextLine!(PS.config)(state.pos);
                break;
            }
            default: break loop;
        }
    }

    static if(hasLengthAndCol)
        state.pos.col += lineStart - state.input.length;

    return strippedSpace;
}

@safe pure unittest
{
    import std.algorithm : equal;
    import std.meta : AliasSeq;
    import std.typecons : tuple;

    foreach(func; testRangeFuncs)
    {
        auto haystack1 = func("  \t\rhello world");

        foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 5)),
                             tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                             tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
        {
            auto state = testParser!(t[0])(haystack1.save);
            assert(state.stripWS());
            assert(equalCU(state.input, "hello world"));
            assert(state.pos == t[1]);
        }

        auto haystack2 = func("  \n \n \n  \nhello world");

        foreach(t; AliasSeq!(tuple(Config.init, SourcePos(5, 1)),
                             tuple(makeConfig(PositionType.line), SourcePos(5, -1)),
                             tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
        {
            auto state = testParser!(t[0])(haystack2.save);
            assert(state.stripWS());
            assert(equalCU(state.input, "hello world"));
            assert(state.pos == t[1]);
        }

        auto haystack3 = func("  \n \n \n  \n  hello world");

        foreach(t; AliasSeq!(tuple(Config.init, SourcePos(5, 3)),
                             tuple(makeConfig(PositionType.line), SourcePos(5, -1)),
                             tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
        {
            auto state = testParser!(t[0])(haystack3.save);
            assert(state.stripWS());
            assert(equalCU(state.input, "hello world"));
            assert(state.pos == t[1]);
        }

        auto haystack4 = func("hello world");

        foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 1)),
                             tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                             tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
        {
            auto state = testParser!(t[0])(haystack4.save);
            assert(!state.stripWS());
            assert(equal(state.input, "hello world"));
            assert(state.pos == t[1]);
        }
    }
}


// Returns a slice (or takeExactly) of state.input up to but not including the
// given text, removing both that slice and the given text from state.input in
// the process. If the text is not found, then an XMLParsingException is thrown.
auto takeUntil(string text, PS)(PS state)
{
    import std.algorithm : find;
    import std.ascii : isWhite;

    static assert(isPointer!PS, "_state.currText was probably passed rather than &_state.currText");
    static assert(text.find!isWhite().empty);

    alias R = typeof(PS.input);
    auto orig = state.input.save;
    bool found = false;
    size_t takeLen = 0;

    static if(state.config.posType == PositionType.lineAndCol)
        size_t lineStart = 0;

    loop: while(!state.input.empty)
    {
        switch(state.input.front)
        {
            case cast(ElementType!R)text[0]:
            {
                static if(text.length == 1)
                {
                    found = true;
                    state.input.popFront();
                    break loop;
                }
                else static if(text.length == 2)
                {
                    state.input.popFront();
                    if(!state.input.empty && state.input.front == text[1])
                    {
                        found = true;
                        state.input.popFront();
                        break loop;
                    }
                    ++takeLen;
                    continue;
                }
                else
                {
                    state.input.popFront();
                    auto saved = state.input.save;
                    foreach(i, c; text[1 .. $])
                    {
                        if(state.input.empty)
                        {
                            takeLen += i + 1;
                            break loop;
                        }
                        if(state.input.front != c)
                        {
                            state.input = saved;
                            ++takeLen;
                            continue loop;
                        }
                        state.input.popFront();
                    }
                    found = true;
                    break loop;
                }
            }
            static if(state.config.posType != PositionType.none)
            {
                case '\n':
                {
                    ++takeLen;
                    nextLine!(state.config)(state.pos);
                    static if(state.config.posType == PositionType.lineAndCol)
                        lineStart = takeLen;
                    break;
                }
            }
            default:
            {
                ++takeLen;
                break;
            }
        }

        state.input.popFront();
    }

    static if(state.config.posType == PositionType.lineAndCol)
        state.pos.col += takeLen - lineStart + text.length;
    if(!found)
        throw new XMLParsingException("Failed to find: " ~ text, state.pos);
    return takeExactly(orig, takeLen);
}

unittest
{
    import std.algorithm : equal;
    import std.exception : assertThrown;
    import std.meta : AliasSeq;
    import std.typecons : tuple;

    foreach(func; testRangeFuncs)
    {
        {
            auto haystack = func("hello world");
            enum needle = "world";

            static foreach(i; 1 .. needle.length)
            {
                foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 7 + i)),
                                     tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                     tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
                {
                    auto state = testParser!(t[0])(haystack.save);
                    assert(equal(state.takeUntil!(needle[0 .. i])(), "hello "));
                    assert(equal(state.input, needle[i .. $]));
                    assert(state.pos == t[1]);
                }
            }
        }
        {
            auto haystack = func("lello world");

            foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 2)),
                                 tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                 tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
            {
                auto state = testParser!(t[0])(haystack.save);
                assert(state.takeUntil!"l"().empty);
                assert(equal(state.input, "ello world"));
                assert(state.pos == t[1]);
            }

            foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 5)),
                                 tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                 tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
            {
                auto state = testParser!(t[0])(haystack.save);
                assert(equal(state.takeUntil!"ll"(), "le"));
                assert(equal(state.input, "o world"));
                assert(state.pos == t[1]);
            }
        }
        {
            auto haystack = func("llello world");

            foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 4)),
                                 tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                 tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
            {
                auto state = testParser!(t[0])(haystack.save);
                assert(equal(state.takeUntil!"le"(), "l"));
                assert(equal(state.input, "llo world"));
                assert(state.pos == t[1]);
            }
        }
        {
            import std.utf : codeLength;
            auto haystack = func("プログラミング in D is great indeed");
            enum len = cast(int)codeLength!(ElementEncodingType!(typeof(haystack)))("プログラミング in D is ");
            enum needle = "great";
            enum remainder = "great indeed";

            static foreach(i; 1 .. needle.length)
            {
                foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, len + i + 1)),
                                     tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                     tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
                {
                    auto state = testParser!(t[0])(haystack.save);
                    assert(equal(state.takeUntil!(needle[0 .. i])(), "プログラミング in D is "));
                    assert(equal(state.input, remainder[i .. $]));
                    assert(state.pos == t[1]);
                }
            }
        }
        foreach(origHaystack; AliasSeq!("", "a", "hello"))
        {
            auto haystack = func(origHaystack);

            foreach(config; AliasSeq!(Config.init, makeConfig(PositionType.line), makeConfig(PositionType.none)))
            {
                auto state = testParser!config(haystack.save);
                assertThrown!XMLParsingException(state.takeUntil!"x"());
            }
        }
        foreach(origHaystack; AliasSeq!("", "l", "lte", "world", "nomatch"))
        {
            auto haystack = func(origHaystack);

            foreach(config; AliasSeq!(Config.init, makeConfig(PositionType.line), makeConfig(PositionType.none)))
            {
                auto state = testParser!config(haystack.save);
                assertThrown!XMLParsingException(state.takeUntil!"le"());
            }
        }
        foreach(origHaystack; AliasSeq!("", "w", "we", "wew", "bwe", "we b", "hello we go", "nomatch"))
        {
            auto haystack = func(origHaystack);

            foreach(config; AliasSeq!(Config.init, makeConfig(PositionType.line), makeConfig(PositionType.none)))
            {
                auto state = testParser!config(haystack.save);
                assertThrown!XMLParsingException(state.takeUntil!"web"());
            }
        }
    }
}


// The front of the input should be text surrounded by single or double quotes.
// This returns a slice of the input containing that text, and the input is
// advanced to one code unit beyond the quote.
auto takeEnquotedText(PS)(PS state)
{
    import std.meta : AliasSeq;
    static assert(isPointer!PS, "_state.currText was probably passed rather than &_state.currText");
    checkNotEmpty(state);
    immutable quote = state.input.front;
    foreach(quoteChar; AliasSeq!(`"`, `'`))
    {
        // This would be a bit simpler if takeUntil took a runtime argument,
        // but in all other cases, a compile-time argument makes more sense, so
        // this seemed like a reasonable way to handle this one case.
        if(quote == quoteChar[0])
        {
            popFrontAndIncCol(state);
            return takeUntil!quoteChar(state);
        }
    }
    throw new XMLParsingException("Expected quoted text", state.pos);
}

unittest
{
    import std.algorithm : equal;
    import std.exception : assertThrown;
    import std.range : only;
    import std.meta : AliasSeq;
    import std.typecons : tuple;

    foreach(func; testRangeFuncs)
    {
        foreach(quote; only("\"", "'"))
        {
            {
                auto haystack = func(quote ~ quote);

                foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 3)),
                                     tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                     tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
                {
                    auto state = testParser!(t[0])(haystack.save);
                    assert(takeEnquotedText(state).empty);
                    assert(state.input.empty);
                    assert(state.pos == t[1]);
                }
            }
            {
                auto haystack = func(quote ~ "hello world" ~ quote);

                foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 14)),
                                     tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                     tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
                {
                    auto state = testParser!(t[0])(haystack.save);
                    assert(equal(takeEnquotedText(state), "hello world"));
                    assert(state.input.empty);
                    assert(state.pos == t[1]);
                }
            }
            {
                auto haystack = func(quote ~ "hello world" ~ quote ~ " foo");

                foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 14)),
                                     tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                     tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
                {
                    auto state = testParser!(t[0])(haystack.save);
                    assert(equal(takeEnquotedText(state), "hello world"));
                    assert(equal(state.input, " foo"));
                    assert(state.pos == t[1]);
                }
            }
            {
                import std.utf : codeLength;
                auto haystack = func(quote ~ "プログラミング " ~ quote ~ "in D");
                enum len = cast(int)codeLength!(ElementEncodingType!(typeof(haystack)))("プログラミング ");

                foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, len + 3)),
                                     tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                     tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
                {
                    auto state = testParser!(t[0])(haystack.save);
                    assert(equal(takeEnquotedText(state), "プログラミング "));
                    assert(equal(state.input, "in D"));
                    assert(state.pos == t[1]);
                }
            }
        }

        foreach(str; only(`hello`, `"hello'`, `"hello`, `'hello"`, `'hello`, ``, `"'`, `"`, `'"`, `'`))
            assertThrown!XMLParsingException(testParser!(Config.init)(func(str)).takeEnquotedText());
    }
}


// Parses
// Eq ::= S? '=' S?
void stripEq(PS)(PS state)
{
    static assert(isPointer!PS, "_state.currText was probably passed rather than &_state.currText");
    stripWS(state);
    if(!stripStartsWith(state, "="))
        throw new XMLParsingException("= missing", state.pos);
    stripWS(state);
}

unittest
{
    import std.algorithm : equal;
    import std.meta : AliasSeq;
    import std.typecons : tuple;

    foreach(func; testRangeFuncs)
    {
        {
            auto haystack = func("=");

            foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 2)),
                                 tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                 tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
            {
                auto state = testParser!(t[0])(haystack.save);
                stripEq(state);
                assert(state.input.empty);
                assert(state.pos == t[1]);
            }
        }
        {
            auto haystack = func("=hello");

            foreach(t; AliasSeq!(tuple(Config.init, SourcePos(1, 2)),
                                 tuple(makeConfig(PositionType.line), SourcePos(1, -1)),
                                 tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
            {
                auto state = testParser!(t[0])(haystack.save);
                stripEq(state);
                assert(equal(state.input, "hello"));
                assert(state.pos == t[1]);
            }
        }
        {
            auto haystack = func(" \n\n =hello");

            foreach(t; AliasSeq!(tuple(Config.init, SourcePos(3, 3)),
                                 tuple(makeConfig(PositionType.line), SourcePos(3, -1)),
                                 tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
            {
                auto state = testParser!(t[0])(haystack.save);
                stripEq(state);
                assert(equal(state.input, "hello"));
                assert(state.pos == t[1]);
            }
        }
        {
            auto haystack = func("=\n\n\nhello");

            foreach(t; AliasSeq!(tuple(Config.init, SourcePos(4, 1)),
                                 tuple(makeConfig(PositionType.line), SourcePos(4, -1)),
                                 tuple(makeConfig(PositionType.none), SourcePos(-1, -1))))
            {
                auto state = testParser!(t[0])(haystack.save);
                stripEq(state);
                assert(equal(state.input, "hello"));
                assert(state.pos == t[1]);
            }
        }
    }
}


pragma(inline, true) void popFrontAndIncCol(PS)(PS state)
{
    static assert(isPointer!PS, "_state.currText was probably passed rather than &_state.currText");
    state.input.popFront();
    nextCol!(PS.config)(state.pos);
}

pragma(inline, true) void nextLine(Config config)(ref SourcePos pos)
{
    static if(config.posType != PositionType.none)
        ++pos.line;
    static if(config.posType == PositionType.lineAndCol)
        pos.col = 1;
}

pragma(inline, true) void nextCol(Config config)(ref SourcePos pos)
{
    static if(config.posType == PositionType.lineAndCol)
        ++pos.col;
}

pragma(inline, true) void checkNotEmpty(PS)(PS state, size_t line = __LINE__)
{
    static assert(isPointer!PS, "_state.currText was probably passed rather than &_state.currText");
    if(state.input.empty)
        throw new XMLParsingException("Prematurely reached end of document", state.pos, __FILE__, line);
}


version(unittest)
{
    // Wrapping it like this rather than assigning testRangeFuncs directly
    // allows us to avoid having the imports be at module-level, which is
    // generally not esirable with version(unittest).
    alias testRangeFuncs = _testRangeFuncs!();
    template _testRangeFuncs()
    {
        import std.conv : to;
        import std.algorithm : filter;
        import std.meta : AliasSeq;
        alias _testRangeFuncs = AliasSeq!(a => to!string(a), a => to!wstring(a), a => to!dstring(a),
                                          a => filter!"true"(a), a => fwdCharRange(a), a => rasRefCharRange(a));
    }
}
