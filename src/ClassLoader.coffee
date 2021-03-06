
{ReferenceClassData,PrimitiveClassData,ArrayClassData} = require './ClassData'
util = require './util'
{trace} = require './logging'
{StackFrame} = require './runtime'
{JavaException} = require './exceptions'
{JavaObject} = require './java_object'

"use strict"

root = exports ? this.ClassLoader = {}

# Base ClassLoader class. Handles interacting with the raw data structure used
# to store the classes.
# Requires a reference to the bootstrap classloader for primitive class
# references.
class ClassLoader
  constructor: (@bootstrap) -> @loaded_classes = Object.create null

  # Remove a class. Should only be used in the event of a class loading failure.
  _rem_class: (type_str) ->
    delete @loaded_classes[type_str]
    return

  # Adds a class to this ClassLoader.
  _add_class: (type_str, cdata) ->
    # XXX: JVM appears to allow define_class to be called twice on same class.
    # Does it actually replace the old class???
    #UNSAFE? || throw new Error "ClassLoader tried to overwrite class #{type_str} with a new version." if @loaded_classes[type_str]?
    @loaded_classes[type_str] = cdata
    return

  # Retrieves a class in this ClassLoader. Returns null if it does not exist.
  _get_class: (type_str) ->
    cdata = @loaded_classes[type_str]
    return if cdata? then cdata else null

  # Defines a new array class with the specified component type.
  # Returns null if the component type is not loaded.
  # Returns the ClassData object for this class (array classes do not have
  # JavaClassObjects).
  _try_define_array_class: (type_str) ->
    component_type = util.get_component_type type_str
    component_cdata = @get_loaded_class(component_type, true)
    return null unless component_cdata?
    return @_define_array_class type_str, component_cdata

  # Defines a new array class with the specified component ClassData.
  # Note that the component ClassData object can come from another ClassLoader.
  _define_array_class: (type_str, component_cdata) ->
    cdata = new ArrayClassData component_cdata.get_type(), @
    @_add_class type_str, cdata
    cdata.set_loaded @bootstrap.get_loaded_class('Ljava/lang/Object;'), component_cdata
    return cdata

  # Called by define_class to fetch all interfaces and superclasses in parallel.
  _parallel_class_load: (rs, types, success_fn, failure_fn) ->
    # Number of callbacks waiting to be called.
    pending_requests = types.length
    # Set to a callback that throws an exception.
    failure = null
    # Array of successfully loaded classes.
    loaded = []

    # Called each time a requests finishes, whether in error or in success.
    request_finished = () ->
      pending_requests--
      # pending_requests is 0? Then I am the last callback. Call success_fn.
      if pending_requests is 0
        unless failure?
          success_fn loaded
        else
          # Throw the exception.
          failure_fn failure

    # Fetches the class data associated with 'type' and adds it to the classloader.
    fetch_data = (type) =>
      @load_class rs, type, ((cdata) ->
        loaded.push cdata
        request_finished()
      ), ((f_fn) ->
        # load_class failure
        failure = f_fn
        request_finished()
      )

    # Kick off all of the requests.
    for type in types
      fetch_data(type)

  # Loads the classes represented by the type strings in types one by one.
  _regular_class_load: (rs, types, success_fn, failure_fn) ->
    return success_fn() unless types.length > 0

    # Array of successfully loaded classes.
    loaded = []

    fetch_class = (type) =>
      @load_class rs, type, ((cdata) ->
        loaded.push cdata
        if types.length > 0
          fetch_class types.shift()
        else
          success_fn loaded
      ), failure_fn

    fetch_class types.shift()

  # Only called for reference types.
  # Ensures that all subclasses and interfaces are also loaded (hence, it is
  # asynchronous).
  # Calls the success_fn with the JavaClassObject for this class.
  # Calls the failure_fn with a function that throws the appropriate exception
  # in the event of a failure.
  # If 'parallel' is 'true', then we call load_class multiple times in
  # parallel (used by the bootstrap classloader).
  define_class: (rs, type_str, data, success_fn, failure_fn, parallel=false) ->
    trace "Defining class #{type_str}..."
    cdata = new ReferenceClassData(data, @)
    # Add the class before we fetch its super class / interfaces.
    @_add_class type_str, cdata
    # What classes are we fetching?
    types = cdata.get_interface_types()
    types.push cdata.get_super_class_type()
    to_load = []
    loaded_already = []
    # Prune any loaded classes.
    for type in types
      continue unless type? # super_class could've been null.
      clsdata = @get_loaded_class type, true
      if clsdata?
        loaded_already.push clsdata
      else
        to_load.push type

    process_loaded_classes = (cdatas) ->
      cdatas = loaded_already.concat cdatas
      super_cdata = null
      interface_cdatas = []
      interface_types = cdata.get_interface_types()
      super_type = cdata.get_super_class_type()
      for a_cdata in cdatas
        type = a_cdata.get_type()
        if type is super_type
          super_cdata = a_cdata
        else
          interface_cdatas.push a_cdata
      cdata.set_loaded super_cdata, interface_cdatas
      setTimeout((->success_fn(cdata.get_class_object rs)), 0)

    if to_load.length > 0
      if parallel
        @_parallel_class_load rs, to_load, process_loaded_classes, failure_fn
      else
        @_regular_class_load rs, to_load, process_loaded_classes, failure_fn
    else
      # Everything is already loaded.
      process_loaded_classes([])

  # Synchronous method that checks if the given class is loaded
  # already, and returns it if so. If it is not, it throws an exception.
  # If null_handled is set, it simply returns null.
  get_loaded_class: (type_str, null_handled=false) ->
    cdata = @_get_class type_str
    return cdata if cdata?

    # If it's an array class, we might be able to get it synchronously...
    if util.is_array_type type_str
      cdata = @_try_define_array_class type_str
      return cdata if cdata?

    # If it's a primitive class, get it from the bootstrap classloader.
    return @bootstrap.get_primitive_class type_str if util.is_primitive_type type_str

    return null if null_handled
    throw new Error "Error in get_loaded_class: Class #{type_str} is not loaded."

  # Same as get_loaded_class, but for initialized classes.
  get_initialized_class: (type_str, null_handled=false) ->
    cdata = @get_loaded_class type_str, true
    return cdata if cdata?.is_initialized()
    return null if null_handled
    throw new Error "Error in get_initialized_class: Class #{type_str} is not initialized."

  # Asynchronously initializes the given class, and passes the ClassData
  # representation to success_fn.
  # Passes a callback to failure_fn that throws an exception in the event of
  # an error.
  # This function makes the assumption that cdata is a ReferenceClassData
  _initialize_class: (rs, cdata, success_fn, failure_fn) ->
    trace "Actually initializing class #{cdata.get_type()}..."
    UNSAFE? || throw new Error "Tried to initialize a non-reference type: #{cdata.get_type()}" unless cdata instanceof ReferenceClassData

    # Iterate through the class hierarchy, pushing StackFrames that run
    # <clinit> functions onto the stack. The last StackFrame pushed will be for
    # the <clinit> function of the topmost uninitialized class in the hierarchy.
    first_clinit = true
    first_native_frame = StackFrame.native_frame("$clinit", (()=>
      throw new Error "The top of the meta stack should be this native frame, but it is not: #{rs.curr_frame().name} at #{rs.meta_stack().length()}" if rs.curr_frame() != first_native_frame
      rs.meta_stack().pop()
      # success_fn is responsible for getting us back into the runtime state
      # execution loop.
      rs.async_op(()=>setTimeout((->success_fn(cdata)), 0))
    ), ((e)=>
      if e instanceof JavaException
        # We hijack the current native frame to transform the exception into a
        # ExceptionInInitializerError, then call failure_fn to throw it.
        # failure_fn is responsible for getting us back into the runtime state
        # loop.
        # We don't use the java_throw helper since this Exception object takes
        # a Throwable as an argument.
        nf = rs.curr_frame()
        nf.runner = =>
          rv = rs.pop()
          rs.meta_stack().pop()
          # Throw the exception.
          throw (new JavaException(rv))
        nf.error = =>
          rs.meta_stack().pop()
          setTimeout((->failure_fn (-> throw e)), 0)

        cls = @bootstrap.get_loaded_class 'Ljava/lang/ExceptionInInitializerError;'
        v = new JavaObject rs, cls # new
        method_spec = sig: '<init>(Ljava/lang/Throwable;)V'
        rs.push_array([v,v,e.exception]) # dup, ldc
        rs.method_lookup(cls, method_spec).setup_stack(rs) # invokespecial
      else
        # Not a Java exception?
        # No idea what this is; let's get outta dodge and rethrow it.
        rs.meta_stack().pop()
        throw e
    ))

    class_file = cdata # XXX: Rename vars.
    while class_file? and not class_file.is_initialized()
      trace "initializing class: #{class_file.toClassString()}"
      class_file.initialized = true

      # Resets any cached state from previous JVM executions (browser).
      class_file.initialize()

      # Run class initialization code. Superclasses get init'ed first.  We
      # don't want to call this more than once per class, so don't do dynamic
      # lookup. See spec [2.17.4][1].
      # [1]: http://docs.oracle.com/javase/specs/jvms/se5.0/html/Concepts.doc.html#19075
      # XXX: Hack. We don't use method_lookup since we want only the method in *this* class.
      clinit = class_file.methods['<clinit>()V']
      if clinit?
        trace "\tFound <clinit>. Pushing stack frame."
        # Push a native frame; needed to handle exceptions and the callback.
        if first_clinit
          trace "\tFirst <clinit> in the loop."
          first_clinit = false
          # The first frame calls success_fn on success. Subsequent frames
          # are only used to handle exceptions.
          rs.meta_stack().push(first_native_frame)
        else
          rs.meta_stack().push StackFrame.native_frame("$clinit_secondary", (()=>
            rs.meta_stack().pop()
          ), ((e)=>
            until @curr_frame() is first_native_frame
              rs.meta_stack.pop()
            rs.meta_stack.pop() # Pop that first native frame.
            # XXX: Wait, does this mean we don't convert properly here?? :(
            # Rethrow the exception. failure_fn is responsible for getting us back
            # into the runtime state loop.
            rs.async_op(()=>setTimeout((->failure_fn(()->throw e)), 0))
          ))
        clinit.setup_stack(rs)
      class_file = class_file.get_super_class()

    unless first_clinit
      # Push ourselves back into the execution loop to run the <clinit> methods.
      rs.run_until_finished((->), false, rs.stashed_done_cb)
      return

    # Classes did not have any clinit functions.
    setTimeout((()=>success_fn(cdata)), 0)
    return

  # Asynchronously loads and initializes the given class, and passes its
  # ClassData representation to success_fn.
  # Passes a callback to failure_fn that throws an exception in the event
  # of an error.
  initialize_class: (rs, type_str, success_fn, failure_fn) ->
    trace "Initializing class #{type_str}..."
    # Let's see if we can do this synchronously.
    # Note that primitive types are guaranteed to be created synchronously
    # here.
    cdata = @get_initialized_class type_str, true
    return setTimeout((()->success_fn cdata), 0) if cdata?

    # If it's an array type, the asynchronous part only involves its
    # component type. Short circuit here.
    if util.is_array_type type_str
      component_type = util.get_component_type type_str
      # Component type doesn't need to be initialized; just loaded.
      @load_class rs, component_type, ((cdata)=>
        setTimeout((()=>success_fn @_define_array_class type_str, cdata), 0)
      ), failure_fn
      return

    # Only reference types will make it to this point. :-)

    # Is it at least loaded?
    cdata = @get_loaded_class type_str, true
    return @_initialize_class(rs, cdata, success_fn, failure_fn) if cdata?

    # OK, OK. We'll have to asynchronously load it AND initialize it.
    @load_class rs, type_str, ((cdata) =>
      # Check if it's initialized already. If this is a CustomClassLoader, it's
      # possible that the class has been retrieved from another ClassLoader,
      # and has already been initialized.
      if cdata.is_initialized(rs)
        setTimeout((->success_fn cdata), 0)
      else
        @_initialize_class rs, cdata, success_fn, failure_fn
    ), failure_fn

  # Loads the class indicated by the given type_str. Passes the ClassFile
  # object for the class to success_fn.
  load_class: (rs, type_str, success_fn, failure_fn) ->
    trace "Loading class #{type_str}... [general]"
    rv = @get_loaded_class type_str, true
    return setTimeout((()->success_fn(rv)), 0) if rv?

    # If it's an array type, the asynchronous part only involves its
    # component type. Short circuit here.
    if util.is_array_type type_str
      component_type = util.get_component_type type_str
      @load_class rs, component_type, ((cdata)=>
        setTimeout((()=>success_fn @_define_array_class type_str, cdata), 0)
      ), failure_fn
      return

    # Unloaded reference class. Let's load it.
    @_load_class rs, type_str, success_fn, failure_fn

# The Bootstrap ClassLoader. This is the only ClassLoader that can create
# primitive types.
class root.BootstrapClassLoader extends ClassLoader
  # read_classfile is an asynchronous method that consumes a type string, a
  # success_fn, and a failure_fn, and passes the ReferenceClassData
  # corresponding to that type string to the success_fn.
  # Passes an error string to failure_fn.
  constructor: (@read_classfile) -> super(@)

  # Returns the given primitive class. Creates it if needed.
  get_primitive_class: (type_str) ->
    cdata = @_get_class type_str
    return cdata if cdata?

    cdata = new PrimitiveClassData type_str, @
    @_add_class type_str, cdata
    return cdata

  # Asynchronously retrieves the given class, and passes its ClassData
  # representation to success_fn.
  # Passes a callback to failure_fn that throws an exception in the event
  # of an error.
  # Called only:
  # * With a type_str referring to a Reference Class.
  # * If the class is not already loaded.
  _load_class: (rs, type_str, success_fn, failure_fn) =>
    trace "ASYNCHRONOUS: load_class #{type_str} [bootstrap]"
    rv = @get_loaded_class type_str, true
    return success_fn(rv) if rv?

    @read_classfile type_str, ((data)=>
      @define_class rs, type_str, data, ((jco)=>success_fn(jco.$cls)), failure_fn, true # Fetch super class/interfaces in parallel.
    ), (() =>
      setTimeout((failure_fn () =>
        rs.java_throw @bootstrap.get_initialized_class('Ljava/lang/ClassNotFoundException;'), util.ext_classname type_str
      ), 0)
    ) # XXX: Convert to correct exception type.
    return

class root.CustomClassLoader extends ClassLoader
  # @loader_obj is the JavaObject for the java/lang/ClassLoader instance that
  # represents this ClassLoader.
  # @bootstrap is an instance of the bootstrap class loader.
  constructor: (bootstrap, @loader_obj) -> super(bootstrap)

  # Asynchronously retrieves the given class, and passes its ClassData
  # representation to success_fn.
  # Passes a callback to failure_fn that throws an exception in the event
  # of an error.
  # Called only:
  # * With a type_str referring to a Reference Class.
  # * If the class is not already loaded.
  _load_class: (rs, type_str, success_fn, failure_fn) ->
    trace "ASYNCHRONOUS: load_class #{type_str} [custom]"
    rs.meta_stack().push StackFrame.native_frame("$#{@loader_obj.cls.get_type()}", (()=>
      jclo = rs.pop()
      rs.meta_stack().pop()

      cls = jclo.$cls
      # If loadClass delegated to another ClassLoader, it will not have called
      # defineClass on the result. If so, we will need to stash this class.
      @_add_class(type_str, cls) unless @_get_class type_str?
      rs.async_op(->setTimeout((->success_fn(cls)), 0))
    ), ((e)=>
      rs.meta_stack().pop()
      # XXX: Convert the exception.
      rs.async_op(->setTimeout((->(failure_fn(->throw e))), 0))
    ))
    rs.push2 @loader_obj, rs.init_string util.ext_classname type_str
    # We don't care about the return value of this function, as
    # define_class handles registering the ClassData with the class loader.
    # define_class also handles recalling load_class for any needed super
    # classes and interfaces.
    @loader_obj.cls.method_lookup(rs, {sig: 'loadClass(Ljava/lang/String;)Ljava/lang/Class;'}).setup_stack(rs)
    # Push ourselves back into the execution loop to run the method.
    rs.run_until_finished((->), false, rs.stashed_done_cb)
    return
