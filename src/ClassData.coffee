
# pull in external modules
util = require './util'
ConstantPool = require './ConstantPool'
attributes = require './attributes'
opcodes = require './opcodes'
methods = null # Define later to avoid circular dependency; methods references natives, natives references ClassData
{JavaObject,JavaClassObject} = require './java_object'
{trace} = require './logging'

"use strict"

root = exports ? this.ClassData = {}

# Represents a single Class in the JVM.
class ClassData
  constructor: (@loader=null) -> # NOP

  # Proxy method for type's method until we get rid of type objects.
  toClassString: () -> @this_class
  toExternalString: () -> util.ext_classname @this_class

  get_class_object: (rs) ->
    @jco = new JavaClassObject(rs, @) unless @jco?
    @jco

  # Spec [5.4.3.2][1].
  # [1]: http://docs.oracle.com/javase/specs/jvms/se5.0/html/ConstantPool.doc.html#77678
  field_lookup: (rs, field_spec) ->
    unless @fl_cache[field_spec.name]?
      @fl_cache[field_spec.name] = @_field_lookup(rs, field_spec)
    return @fl_cache[field_spec.name]

  _field_lookup: (rs, field_spec) ->
    for field in @fields
      if field.name is field_spec.name
        return field

    # These may not be initialized! But we have them loaded.
    for ifc_cls in @get_interfaces()
      field = ifc_cls.field_lookup(rs, field_spec)
      return field if field?

    sc = @get_super_class()
    if sc?
      field = sc.field_lookup(rs, field_spec)
      return field if field?
    return null

  # Spec [5.4.3.3][1], [5.4.3.4][2].
  # [1]: http://docs.oracle.com/javase/specs/jvms/se5.0/html/ConstantPool.doc.html#79473
  # [2]: http://docs.oracle.com/javase/specs/jvms/se5.0/html/ConstantPool.doc.html#78621
  method_lookup: (rs, method_spec) ->
    unless @ml_cache[method_spec.sig]?
      @ml_cache[method_spec.sig] = @_method_lookup(rs, method_spec)
    return @ml_cache[method_spec.sig]

  _method_lookup: (rs, method_spec) ->
    method = @methods[method_spec.sig]
    return method if method?

    parent = @get_super_class()
    if parent?
      method = parent.method_lookup(rs, method_spec)
      return method if method?

    for ifc in @get_interfaces()
      method = ifc.method_lookup(rs, method_spec)
      return method if method?

    return null

  static_get: (rs, name) ->
    return @static_fields[name] unless @static_fields[name] is undefined
    rs.java_throw @loader.get_initialized_class('Ljava/lang/NoSuchFieldError;'), name

  static_put: (rs, name, val) ->
    unless @static_fields[name] is undefined
      @static_fields[name] = val
    else
      rs.java_throw @loader.get_initialized_class('Ljava/lang/NoSuchFieldError;'), name

  # Resets any ClassData state that may have been built up
  load: () ->
    @initialized = false
    @jco = null

  # "Reinitializes" the ClassData for subsequent JVM invocations. Resets all
  # of the built up state / caches present in the opcode instructions.
  # Eventually, this will also handle `clinit` duties.
  initialize: () ->
    unless @initialized
      @static_fields = @_construct_static_fields()
      for method in @methods
        method.initialize()

  construct_default_fields: (rs) ->
    # init fields from this and inherited ClassDatas
    cls = @
    # Object.create(null) avoids interference with Object.prototype's properties
    @default_fields = Object.create null
    while cls?
      for f in cls.fields when not f.access_flags.static
        val = util.initial_value f.raw_descriptor
        @default_fields[cls.get_type() + f.name] = val
      cls = cls.get_super_class()
    return

  # Used internally to reconstruct @static_fields
  _construct_static_fields: ->
    static_fields = Object.create null
    for f in @fields when f.access_flags.static
      static_fields[f.name] = util.initial_value f.raw_descriptor
    return static_fields

  get_default_fields: (rs) ->
    return @default_fields unless @default_fields is undefined
    @construct_default_fields(rs)
    return @default_fields

  # Checks if the class file is initialized. It will set @initialized to 'true'
  # if this class has no static initialization method and its parent classes
  # are initialized, too.
  is_initialized: ->
    return true if @initialized
    # XXX: Hack to avoid traversing hierarchy.
    return false if @methods['<clinit>()V']?
    @initialized = if @get_super_class()?.is_initialized() else false
    return @initialized

  # Returns the JavaObject object of the classloader that initialized this
  # class. Returns null for the default classloader.
  get_class_loader: () -> @loader
  # Returns the unique ID of this class loader. Returns null for the bootstrap
  # classloader.
  get_class_loader_id: () -> @loader?.ref or null

  # Returns 'true' if I am a subclass of target.
  is_subclass: (rs, target) ->
    return true if @this_class is target.this_class
    return false unless @get_super_class()?  # I'm java/lang/Object, can't go further
    return @get_super_class().is_subclass rs, target

  # Returns 'true' if I implement the target interface.
  is_subinterface: (rs, target) ->
    return true if @this_class is target.this_class
    for super_iface in @get_interfaces()
      return true if super_iface.is_subinterface rs, target
    return false unless @get_super_class()?  # I'm java/lang/Object, can't go further
    return @get_super_class().is_subinterface rs, target

  # Get the typestring for the superclass of this class.
  get_super_class_type: -> @super_class
  # Get all of the typestrings for the interfaces implemented by this class.
  get_interface_types: -> @constant_pool.get(i).deref() for i in @interfaces
  # Get the ClassData object representing this class's superclass.
  get_super_class: -> @super_class_cdata
  # Get an array of ClassData objects representing this class's interfaces.
  get_interfaces: -> @interface_cdatas
  get_type: -> @this_class

# Represents a "reference" Class -- that is, a class that neither represents a
# primitive nor an array.
class root.ReferenceClassData extends ClassData
  constructor: (bytes_array, @loader=null) ->
    # XXX: Circular dependency hack.
    unless methods? then methods = require './methods'

    bytes_array = new util.BytesArray bytes_array
    throw "Magic number invalid" if (bytes_array.get_uint 4) != 0xCAFEBABE
    @minor_version = bytes_array.get_uint 2
    @major_version = bytes_array.get_uint 2
    throw "Major version invalid" unless 45 <= @major_version <= 51
    @constant_pool = new ConstantPool
    @constant_pool.parse(bytes_array)
    # bitmask for {public,final,super,interface,abstract} class modifier
    @access_byte = bytes_array.get_uint 2
    @access_flags = util.parse_flags @access_byte
    @this_class  = @constant_pool.get(bytes_array.get_uint 2).deref()
    # super reference is 0 when there's no super (basically just java.lang.Object)
    super_ref = bytes_array.get_uint 2
    @super_class = @constant_pool.get(super_ref).deref() unless super_ref is 0
    # direct interfaces of this class
    isize = bytes_array.get_uint 2
    @interfaces = (bytes_array.get_uint 2 for i in [0...isize] by 1)
    # fields of this class
    num_fields = bytes_array.get_uint 2
    @fields = (new methods.Field(@) for i in [0...num_fields] by 1)
    @fl_cache = {}

    for f,i in @fields
      f.parse(bytes_array,@constant_pool,i)
      @fl_cache[f.name] = f
    # class methods
    num_methods = bytes_array.get_uint 2
    @methods = {}
    # It would probably be safe to make @methods the @ml_cache, but it would
    # make debugging harder as you would lose track of who owns what method.
    @ml_cache = {}
    for i in [0...num_methods] by 1
      m = new methods.Method(@)
      m.parse(bytes_array,@constant_pool,i)
      mkey = m.name + m.raw_descriptor
      @methods[mkey] = m
      @ml_cache[mkey] = m
    # class attributes
    @attrs = attributes.make_attributes(bytes_array,@constant_pool)
    throw "Leftover bytes in classfile: #{bytes_array}" if bytes_array.has_bytes()

    @jco = null
    @initialized = false # Has clinit been run?
    # Contains the value of all static fields. Will be reset when initialize()
    # is run.
    @static_fields = @_construct_static_fields()

  # Called once this class is loaded.
  set_loaded: (@super_class_cdata, interface_cdatas) ->
    @interface_cdatas = if interface_cdatas? then interface_cdatas else []

  # Returns a boolean indicating if this class is an instance of the target class.
  # "target" is a ClassData object.
  # The ClassData objects do not need to be initialized; just loaded.
  # See §2.6.7 for casting rules.
  is_castable: (rs, target) ->
    return false unless target instanceof root.ReferenceClassData

    if @access_flags.interface
      # We are both interfaces
      if target.access_flags.interface then return @is_subinterface(rs,target)
      # Only I am an interface
      return target.toClassString() is 'Ljava/lang/Object;' unless target.access_flags.interface
    else
      # I am a regular class, target is an interface
      if target.access_flags.interface then return @is_subinterface(rs,target)
      # We are both regular classes
      return @is_subclass(rs,target)

class root.ArrayClassData extends ClassData
  constructor: (@component_type, @loader=null) ->
    @constant_pool = new ConstantPool
    @ml_cache = {}
    @fl_cache = {}
    @access_flags = {}
    @this_class = "[#{@component_type}"
    @super_class = 'Ljava/lang/Object;'
    @interfaces = []
    @fields = []
    @methods = {}
    @attrs = []
    @initialized = false
    @static_fields = []

  get_component_type: () -> return @component_type

  # Returns a boolean indicating if this class is an instance of the target class.
  # "target" is a ClassData object.
  # The ClassData objects do not need to be initialized; just loaded.
  # See §2.6.7 for casting rules.
  is_castable: (rs, target) -> # target is c2
    unless target instanceof root.ArrayClassData
      return false if target instanceof root.PrimitiveClassData
      # Must be a reference type.
      if target.access_flags.interface
        # Interface reference type
        return target.toClassString() in ['Ljava/lang/Cloneable;','Ljava/io/Serializable;']
      # Non-interface reference type
      return target.toClassString() is 'Ljava/lang/Object;'

    # We are both array types, so it only matters if my component type can be
    # cast to its component type.
    return @get_component_class().is_castable(rs, target.get_component_class())

  # Arrays need no initialization.
  is_initialized: -> true

  # Called once this class is loaded.
  set_loaded: (@super_class_cdata, @component_class_cdata) -> # Nothing else to do.
  get_component_class: -> return @component_class_cdata

class root.PrimitiveClassData extends ClassData
  constructor: (@this_class, @loader=null) ->
    @constant_pool = new ConstantPool
    @ml_cache = {}
    @fl_cache = {}
    @access_flags = {}
    @super_class = null
    @interfaces = []
    @fields = []
    @methods = {}
    @attrs = []
    @initialized = true
    @static_fields = []

  # Returns a boolean indicating if this class is an instance of the target class.
  # "target" is a ClassData object.
  # The ClassData objects do not need to be initialized; just loaded.
  is_castable: (rs, target) -> @this_class == target.this_class

  # Primitive classes are initialized when they are created.
  is_initialized: -> true

  create_wrapper_object: (rs, value) ->
    type_desc = switch @this_class
      when 'B' then 'Ljava/lang/Byte;'
      when 'C' then 'Ljava/lang/Character;'
      when 'D' then 'Ljava/lang/Double;'
      when 'F' then 'Ljava/lang/Float;'
      when 'I' then 'Ljava/lang/Integer;'
      when 'J' then 'Ljava/lang/Long;'
      when 'S' then 'Ljava/lang/Short;'
      when 'Z' then 'Ljava/lang/Boolean;'
      else
        throw new Error("Tried to create_wrapper_object for type #{@this_class}")
    # these are all initialized in preinit (for the BSCL, at least)
    wrapped = new JavaObject rs, rs.get_bs_class(type_desc)
    # HACK: all primitive wrappers store their value in a private static final field named 'value'
    wrapped.fields[type_desc+'value'] = value
    return wrapped