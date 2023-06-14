#include <typeinfo>

#include <memory>
#include <boost/tuple/tuple.hpp>

#include <rtt/types/Types.hpp>
#include <rtt/types/TypekitPlugin.hpp>
#include <rtt/types/TypekitRepository.hpp>
#include <rtt/typekit/RealTimeTypekit.hpp>
#include <rtt/base/PortInterface.hpp>
#include <rtt/transports/corba/TransportPlugin.hpp>
#include <rtt/transports/corba/CorbaConnPolicy.hpp>
#include <rtt/plugin/PluginLoader.hpp>

#include <rtt/base/OutputPortInterface.hpp>
#include <rtt/base/InputPortInterface.hpp>

#include <rtt/transports/corba/CorbaLib.hpp>
#ifdef HAS_MQUEUE
#include <rtt/transports/mqueue/MQLib.hpp>
#include <fcntl.h>
#include <sys/stat.h>
#include <mqueue.h>
#include <boost/lexical_cast.hpp>
#endif

#include "rorocos.hh"
#include "corba.hh"
#include <typelib_ruby.hh>
#include <ruby/version.h>

using namespace std;
using namespace boost;
using namespace RTT::corba;

VALUE mOrocos;
VALUE mCORBA;
VALUE eComError;
VALUE eCORBA;
VALUE eCORBAComError;
VALUE eCORBATimeoutError;
VALUE cNameService;
VALUE cTaskContext;
VALUE eNotFound;
VALUE eNotInitialized;
VALUE eBlockingCallInForbiddenThread = Qnil;
VALUE threadInterdiction = Qnil;
VALUE corbaAccess = Qnil;


static VALUE cInputPort;
static VALUE cOutputPort;
static VALUE cPortAccess;
static VALUE cPort;
static VALUE eConnectionFailed;
static VALUE eStateTransitionFailed;

extern void Orocos_init_CORBA();
extern void Orocos_init_ROS(VALUE mOrocos, VALUE eComError);
extern void Orocos_init_data_handling(VALUE cTaskContext);
extern void Orocos_init_methods();
extern void Orocos_init_ruby_task_context(VALUE mOrocos, VALUE cTaskContext, VALUE cOutputPort, VALUE cInputPort);
static RTT::corba::CConnPolicy policyFromHash(VALUE options);

RTT::types::TypeInfo* get_type_info(std::string const& name, bool do_check)
{
    RTT::types::TypeInfoRepository::shared_ptr type_registry = RTT::types::TypeInfoRepository::Instance();
    RTT::types::TypeInfo* ti = type_registry->type(name);
    if (do_check && ! ti)
        rb_raise(rb_eArgError, "type '%s' is not registered in the RTT type system", name.c_str());
    return ti;
}

RTT::corba::CorbaTypeTransporter* get_corba_transport(std::string const& name, bool do_check)
{
    RTT::types::TypeInfo* ti = get_type_info(name, do_check);
    if (!ti) return 0;
    return get_corba_transport(ti, do_check);
}

RTT::corba::CorbaTypeTransporter* get_corba_transport(RTT::types::TypeInfo* ti, bool do_check)
{
    if (ti->hasProtocol(ORO_CORBA_PROTOCOL_ID))
        return dynamic_cast<RTT::corba::CorbaTypeTransporter*>(ti->getProtocol(ORO_CORBA_PROTOCOL_ID));
    else if (do_check)
        rb_raise(rb_eArgError, "type '%s' does not have a CORBA transport", ti->getTypeName().c_str());
    else
        return 0;
}

orogen_transports::TypelibMarshallerBase* get_typelib_transport(std::string const& name, bool do_check)
{
    RTT::types::TypeInfo* ti = get_type_info(name, do_check);
    if (!ti) return 0;
    return get_typelib_transport(ti, do_check);
}

orogen_transports::TypelibMarshallerBase* get_typelib_transport(RTT::types::TypeInfo* ti, bool do_check)
{
    if (ti->hasProtocol(orogen_transports::TYPELIB_MARSHALLER_ID))
        return dynamic_cast<orogen_transports::TypelibMarshallerBase*>(ti->getProtocol(orogen_transports::TYPELIB_MARSHALLER_ID));
    else if (do_check)
        rb_raise(rb_eArgError, "type '%s' does not have a typelib transport", ti->getTypeName().c_str());
    else
        return 0;
}

boost::tuple<RTaskContext*, VALUE, VALUE> getPortReference(VALUE port)
{
    VALUE task = rb_iv_get(port, "@task");
    VALUE task_name = rb_iv_get(task, "@name");
    VALUE port_name = rb_iv_get(port, "@name");

    RTaskContext& task_context = get_wrapped<RTaskContext>(task);
    return boost::make_tuple(&task_context, task_name, port_name);
}

// call-seq:
//  TaskContext.new(ior,process=Hash.new) => task
//
// Returns the TaskContext instance representing the remote task context
// with the given ior. Raises Orocos::NotFound if the task does
// not exist. Use the CORBA name service to retrieve a task
// by its name.
///
VALUE task_context_create(int argc, VALUE *argv,VALUE klass)
{
    corba_must_be_initialized();

    // all parametes are forwarded to ruby initialize
    if(argc < 1)
        rb_raise(rb_eArgError, "no ior given");
    std::string ior(StringValueCStr(argv[0]));

    RTaskContext *context =  corba_blocking_fct_call_with_result(boost::bind(&CorbaAccess::createRTaskContext,CorbaAccess::instance(),ior));
    VALUE obj = simple_wrap(klass, context);
#if RUBY_API_VERSION_CODE >= 20700
    rb_obj_call_init_kw(obj,argc,argv,RB_PASS_CALLED_KEYWORDS);
#else
    rb_obj_call_init(obj,argc,argv);
#endif
    return obj;
}

static VALUE task_context_equal_p(VALUE self, VALUE other)
{
    if (!rb_obj_is_kind_of(other, cTaskContext))
        return Qfalse;

    RTaskContext& self_  = get_wrapped<RTaskContext>(self);
    RTaskContext& other_ = get_wrapped<RTaskContext>(other);
    return self_.task->_is_equivalent(other_.task) ? Qtrue : Qfalse;
}

// call-seq:
//   task.has_port?(name) => true or false
//
// Returns true if the given name is the name of a port on this task context,
// and false otherwise
//
static VALUE task_context_has_port_p(VALUE self, VALUE name)
{
    RTaskContext& context = get_wrapped<RTaskContext>(self);
    corba_blocking_fct_call(bind(&_objref_CDataFlowInterface::getPortType,(CDataFlowInterface_ptr)context.ports,StringValuePtr(name)));
    return Qtrue;
}

static VALUE task_context_real_name(VALUE self)
{
    RTaskContext& context = get_wrapped<RTaskContext>(self);
    return rb_str_new2(context.name.c_str());
}

static VALUE task_context_has_operation_p(VALUE self, VALUE name)
{
    RTaskContext& context = get_wrapped<RTaskContext>(self);
    corba_blocking_fct_call(bind(&_objref_COperationInterface::getResultType,(_objref_COperationInterface*)context.main_service,StringValuePtr(name)));
    return Qtrue;
}

static VALUE task_context_attribute_type_name(VALUE self, VALUE name)
{
    RTaskContext& context = get_wrapped<RTaskContext>(self);
    std::string const expected_name = StringValuePtr(name);
    CORBA::String_var attribute_type_name =
        corba_blocking_fct_call_with_result(bind(&_objref_CConfigurationInterface::getAttributeTypeName,(_objref_CConfigurationInterface*)context.main_service,StringValuePtr(name)));
    std::string type_name = std::string(attribute_type_name);
    if (type_name != "na")
        return rb_str_new(type_name.c_str(), type_name.length());

    rb_raise(rb_eArgError, "no such attribute %s", StringValuePtr(name));
    return Qfalse;
}

static VALUE task_context_property_type_name(VALUE self, VALUE name)
{
    RTaskContext& context = get_wrapped<RTaskContext>(self);
    std::string const expected_name = StringValuePtr(name);
    CORBA::String_var attribute_type_name =
        corba_blocking_fct_call_with_result(bind(&_objref_CConfigurationInterface::getPropertyTypeName,(_objref_CConfigurationInterface*)context.main_service,StringValuePtr(name)));
    std::string type_name = std::string(attribute_type_name);
    if (type_name != "na")
        return rb_str_new(type_name.c_str(), type_name.length());

    rb_raise(rb_eArgError, "no such property %s", StringValuePtr(name));
    return Qfalse;
}

static VALUE task_context_property_names(VALUE self)
{
    RTaskContext& context = get_wrapped<RTaskContext>(self);

    VALUE result = rb_ary_new();
    RTT::corba::CConfigurationInterface::CPropertyNames_var names =
        corba_blocking_fct_call_with_result(bind(&_objref_CConfigurationInterface::getPropertyList,(_objref_CConfigurationInterface*)context.main_service));
    for (unsigned int i = 0; i != names->length(); ++i)
    {
        CORBA::String_var name = names[i].name;
        rb_ary_push(result, rb_str_new2(name));
    }
    return result;
}

static VALUE task_context_attribute_names(VALUE self)
{
    RTaskContext& context = get_wrapped<RTaskContext>(self);

    VALUE result = rb_ary_new();
    RTT::corba::CConfigurationInterface::CAttributeNames_var names =
        corba_blocking_fct_call_with_result(bind(&_objref_CConfigurationInterface::getAttributeList,(_objref_CConfigurationInterface*)context.main_service));
    for (unsigned int i = 0; i != names->length(); ++i)
    {
        #if RTT_VERSION_GTE(2,8,99)
            CORBA::String_var name = names[i].name;
        #else
            CORBA::String_var name = names[i];
        #endif
        rb_ary_push(result, rb_str_new2(name));
    }
    return result;
}

static VALUE task_context_operation_names(VALUE self)
{
    RTaskContext& context = get_wrapped<RTaskContext>(self);

    VALUE result = rb_ary_new();
    #if RTT_VERSION_GTE(2,8,99)
        RTT::corba::COperationInterface::COperationDescriptions_var names =
                corba_blocking_fct_call_with_result(bind(&_objref_COperationInterface::getOperations,(_objref_COperationInterface*)context.main_service));
    #else
        RTT::corba::COperationInterface::COperationList_var names =
                corba_blocking_fct_call_with_result(bind(&_objref_COperationInterface::getOperations,(_objref_COperationInterface*)context.main_service));
    #endif

    for (unsigned int i = 0; i != names->length(); ++i)
    {
        #if RTT_VERSION_GTE(2,8,99)
            CORBA::String_var name = names[i].name;
        #else
            CORBA::String_var name = names[i];
        #endif
        rb_ary_push(result, rb_str_new2(name));
    }
    return result;
}

// call-seq:
//   task.do_port(name) => port
//
// Returns the Orocos::DataPort or Orocos::BufferPort object representing the
// remote port +name+. Raises NotFound if the port does not exist. This is an
// internal method. Use TaskContext#port to get a port object.
///
static VALUE task_context_do_port(VALUE self, VALUE name, VALUE model)
{
    RTaskContext& context = get_wrapped<RTaskContext>(self);
    RTT::corba::CPortType port_type;
    CORBA::String_var    type_name;
    port_type = corba_blocking_fct_call_with_result(bind(&_objref_CDataFlowInterface::getPortType,(_objref_CDataFlowInterface*)context.ports,StringValuePtr(name)));
    type_name = corba_blocking_fct_call_with_result(bind(&_objref_CDataFlowInterface::getDataType,(_objref_CDataFlowInterface*)context.ports,StringValuePtr(name)));

    VALUE obj = Qnil;
    VALUE args[4] = { self, rb_str_dup(name), rb_str_new2(type_name), model };
    if (port_type == RTT::corba::CInput)
        obj = rb_class_new_instance(4, args, cInputPort);
    else if (port_type == RTT::corba::COutput)
        obj = rb_class_new_instance(4, args, cOutputPort);

    return obj;
}

static VALUE orocos_registered_type_p(VALUE mod, VALUE type_name)
{
    RTT::types::TypeInfo* ti = get_type_info(static_cast<char const*>(StringValuePtr(type_name)), false);
    return ti ? Qtrue : Qfalse;
}

static VALUE orocos_typelib_type_for(VALUE mod, VALUE type_name)
{
    RTT::types::TypeInfo* ti = get_type_info(static_cast<char const*>(StringValuePtr(type_name)), false);
    if (!ti)
        rb_raise(rb_eArgError, "the type %s is not registered in the RTT type system, has the typekit been generated by orogen ?",
                StringValuePtr(type_name));

    if (ti->hasProtocol(orogen_transports::TYPELIB_MARSHALLER_ID))
    {
        orogen_transports::TypelibMarshallerBase* transport =
            dynamic_cast<orogen_transports::TypelibMarshallerBase*>(ti->getProtocol(orogen_transports::TYPELIB_MARSHALLER_ID));
        return rb_str_new2(transport->getMarshallingType());
    }
    else return Qnil;
}

static VALUE task_context_port_names(VALUE self)
{
    VALUE result = rb_ary_new();
    RTaskContext& context = get_wrapped<RTaskContext>(self);
    RTT::corba::CDataFlowInterface::CPortNames_var ports =
        corba_blocking_fct_call_with_result(bind(&_objref_CDataFlowInterface::getPorts,(_objref_CDataFlowInterface*)context.ports));

    for (unsigned int i = 0; i < ports->length(); ++i)
        rb_ary_push(result, rb_str_new2(ports[i]));

    return result;
}

// call-seq:
//  task.state => value
//
// Returns the state of the task, as an integer value. The possible values are
// represented by the various +STATE_+ constants:
//
//   STATE_PRE_OPERATIONAL
//   STATE_STOPPED
//   STATE_ACTIVE
//   STATE_RUNNING
//   STATE_RUNTIME_WARNING
//   STATE_RUNTIME_ERROR
//   STATE_FATAL_ERROR
//
// See Orocos own documentation for their meaning
///
static VALUE task_context_state(VALUE task)
{
    RTaskContext& context = get_wrapped<RTaskContext>(task);
    return INT2FIX(corba_blocking_fct_call_with_result(boost::bind(&_objref_CTaskContext::getTaskState,(CTaskContext_ptr)context.task)));
}

static VALUE call_checked_state_change(VALUE task, char const* msg, bool (RTT::corba::_objref_CTaskContext::*m)())
{
    RTaskContext& context = get_wrapped<RTaskContext>(task);
    RTT::corba::_objref_CTaskContext& obj = *context.task;
    if (!(corba_blocking_fct_call_with_result(boost::bind(m,&obj))))
        rb_raise(eStateTransitionFailed, "%s", msg);
    return Qnil;
}

// Do the transition between STATE_PRE_OPERATIONAL and STATE_STOPPED
static VALUE task_context_configure(VALUE task)
{
    return call_checked_state_change(task, "failed to configure", &RTT::corba::_objref_CTaskContext::configure);
}

// Do the transition between STATE_STOPPED and STATE_RUNNING
static VALUE task_context_start(VALUE task)
{
    return call_checked_state_change(task, "failed to start", &RTT::corba::_objref_CTaskContext::start);
}

// Do the transition between STATE_RUNNING and STATE_STOPPED
static VALUE task_context_stop(VALUE task)
{
    return call_checked_state_change(task, "failed to stop", &RTT::corba::_objref_CTaskContext::stop);
}

// Do the transition between STATE_STOPPED and STATE_PRE_OPERATIONAL
static VALUE task_context_cleanup(VALUE task)
{
    return call_checked_state_change(task, "failed to cleanup", &RTT::corba::_objref_CTaskContext::cleanup);
}

// Do the transition between STATE_EXCEPTION and STATE_STOPPED
static VALUE task_context_reset_exception(VALUE task)
{
    return call_checked_state_change(task, "failed to transition from the Exception state to Stopped", &RTT::corba::_objref_CTaskContext::resetException);
}

/* call-seq:
 *  port.connected? => true or false
 *
 * Tests if this port is already part of a connection or not
 */
static VALUE port_connected_p(VALUE self)
{
    RTaskContext* task; VALUE name;
    tie(task, tuples::ignore, name) = getPortReference(self);
    bool result = corba_blocking_fct_call_with_result(bind(&_objref_CDataFlowInterface::isConnected,(_objref_CDataFlowInterface*)task->ports,
                                                      StringValuePtr(name)));
    return result ? Qtrue : Qfalse;
}

static RTT::corba::CConnPolicy policyFromHash(VALUE options)
{
    RTT::corba::CConnPolicy result = toCORBA(RTT::ConnPolicy());
    VALUE conn_type_value = rb_hash_aref(options, ID2SYM(rb_intern("type")));
    VALUE conn_type = SYM2ID(conn_type_value);
    if (conn_type == rb_intern("data"))
        result.type = RTT::corba::CData;
    else if (conn_type == rb_intern("buffer"))
        result.type = RTT::corba::CBuffer;
    else if (conn_type == rb_intern("circular_buffer"))
        result.type = RTT::corba::CCircularBuffer;
    else
    {
        VALUE obj_as_str = rb_funcall(conn_type_value, rb_intern("inspect"), 0);
        rb_raise(rb_eArgError, "invalid connection type %s", StringValuePtr(obj_as_str));
    }

    result.transport = NUM2INT(rb_hash_aref(options, ID2SYM(rb_intern("transport"))));
    result.data_size = NUM2INT(rb_hash_aref(options, ID2SYM(rb_intern("data_size"))));
    result.init = RTEST(rb_hash_aref(options, ID2SYM(rb_intern("init"))));
    result.pull = RTEST(rb_hash_aref(options, ID2SYM(rb_intern("pull"))));
    result.size = NUM2INT(rb_hash_aref(options, ID2SYM(rb_intern("size"))));
    VALUE name_id = rb_hash_aref(options, ID2SYM(rb_intern("name_id")));
    result.name_id = CORBA::string_dup(StringValuePtr(name_id));

    VALUE lock_type = SYM2ID(rb_hash_aref(options, ID2SYM(rb_intern("lock"))));
    if (lock_type == rb_intern("locked"))
        result.lock_policy = RTT::corba::CLocked;
    else if (lock_type == rb_intern("lock_free"))
        result.lock_policy = RTT::corba::CLockFree;
    else if (lock_type == rb_intern("unsync"))
        result.lock_policy = RTT::corba::CUnsync;
    else
    {
        VALUE obj_as_str = rb_funcall(lock_type, rb_intern("to_s"), 0);
        rb_raise(rb_eArgError, "invalid locking type %s", StringValuePtr(obj_as_str));
    }
    return result;
}

/* Actual implementation of #connect_to. Sanity checks are done in Ruby. Just
 * create the connection.
 */
static VALUE do_port_connect_to(VALUE routput_port, VALUE rinput_port, VALUE options)
{
    RTaskContext* out_task; VALUE out_name;
    tie(out_task, tuples::ignore, out_name) = getPortReference(routput_port);
    RTaskContext* in_task; VALUE in_name;
    tie(in_task, tuples::ignore, in_name) = getPortReference(rinput_port);

    RTT::corba::CConnPolicy policy = policyFromHash(options);
    bool result = corba_blocking_fct_call_with_result(bind(&_objref_CDataFlowInterface::createConnection,(_objref_CDataFlowInterface*)out_task->ports,
                StringValuePtr(out_name),in_task->ports,StringValuePtr(in_name),policy));
    if(!result)
        rb_raise(eConnectionFailed, "failed to connect ports");
    return Qnil;
}

static VALUE do_port_disconnect_all(VALUE port)
{
    RTaskContext* task; VALUE name;
    tie(task, tuples::ignore, name) = getPortReference(port);
    corba_blocking_fct_call(bind(&_objref_CDataFlowInterface::disconnectPort,(_objref_CDataFlowInterface*)task->ports,
                            StringValuePtr(name)));
    return Qnil;
}

static VALUE do_port_disconnect_from(VALUE self, VALUE other)
{
    RTaskContext* self_task; VALUE self_name;
    tie(self_task, tuples::ignore, self_name) = getPortReference(self);
    RTaskContext* other_task; VALUE other_name;
    tie(other_task, tuples::ignore, other_name) = getPortReference(other);
    bool result = corba_blocking_fct_call_with_result(bind(&_objref_CDataFlowInterface::removeConnection,(_objref_CDataFlowInterface*)self_task->ports,
                StringValuePtr(self_name),other_task->ports,StringValuePtr(other_name)));
    return result ? Qtrue : Qfalse;
}

static VALUE do_port_create_stream(VALUE rport, VALUE _policy)
{
    RTaskContext* task; VALUE name;
    tie(task, tuples::ignore, name) = getPortReference(rport);

    RTT::corba::CConnPolicy policy = policyFromHash(_policy);
    bool result = corba_blocking_fct_call_with_result(bind(&_objref_CDataFlowInterface::createStream,(_objref_CDataFlowInterface*)task->ports,
                StringValuePtr(name),policy));
    if(!result)
        rb_raise(eConnectionFailed, "failed to create stream");
    return Qnil;
}

static VALUE do_port_remove_stream(VALUE rport, VALUE stream_name)
{
    RTaskContext* task; VALUE name;
    tie(task, tuples::ignore, name) = getPortReference(rport);

    corba_blocking_fct_call(bind(&_objref_CDataFlowInterface::removeStream,(_objref_CDataFlowInterface*)task->ports,
                            StringValuePtr(name),StringValuePtr(stream_name)));
    return Qnil;
}

/* Document-class: Orocos::NotFound
 *
 * This exception is raised every time an Orocos object is required by name,
 * but the object does not exist.
 *
 * See for instance Orocos::TaskContext.get or Orocos::TaskContext#port
 */
/* Document-class: Orocos::Attribute
 *
 * Attributes and properties are in Orocos ways to parametrize the task contexts.
 * Instances of Orocos::Attribute actually represent both at the same time.
 */
/* Document-module: Orocos
 */
namespace RTT
{
    namespace Corba
    {
        extern int loadCorbaLib();
    }
}

static VALUE orocos_load_standard_typekits(VALUE mod)
{
    // load the default toolkit and the CORBA transport
    RTT::types::TypekitRepository::Import(new RTT::types::RealTimeTypekitPlugin);
    RTT::types::TypekitRepository::Import(new RTT::corba::CorbaLibPlugin);
#ifdef HAS_MQUEUE
    RTT::types::TypekitRepository::Import(new RTT::mqueue::MQLibPlugin);
#endif
    //TODO loadCorbaLib();
    return Qnil;
}

static VALUE orocos_load_rtt_typekit(VALUE orocos, VALUE path)
{
    try
    {
        return RTT::plugin::PluginLoader::Instance()->loadLibrary(StringValuePtr(path)) ? Qtrue : Qfalse;
    }
    catch(std::runtime_error e)
    {
        rb_raise(rb_eArgError, "%s", e.what());
    }
}

static VALUE orocos_load_rtt_plugin(VALUE orocos, VALUE path)
{
    try
    {
        return RTT::plugin::PluginLoader::Instance()->loadLibrary(StringValuePtr(path)) ? Qtrue : Qfalse;
    }
    catch(std::runtime_error e)
    {
        rb_raise(rb_eArgError, "%s", e.what());
    }
}

#ifdef HAS_MQUEUE
static VALUE try_mq_open(VALUE mod)
{
    int this_pid = getpid();
    std::string queue_name = std::string("/orocosrb_") + boost::lexical_cast<std::string>(this_pid);

    mq_attr attributes;
    attributes.mq_flags = 0;
    attributes.mq_maxmsg = 1;
    attributes.mq_msgsize = 1;
    mqd_t setup = mq_open(queue_name.c_str(), O_RDWR | O_CREAT, S_IREAD | S_IWRITE, &attributes);
    if (setup == -1)
        return rb_str_new2(strerror(errno));
    else
    {
        mq_close(setup);
        mq_unlink(queue_name.c_str());
        return Qnil;
    }
}

/* call-seq:
 *   Orocos::MQueue.transportable_type_names => name_list
 *
 * Returns an array of string that are the type names which can be transported
 * over the MQ layer
 */
static VALUE mqueue_transportable_type_names(VALUE mod)
{
    RTT::types::TypeInfoRepository::shared_ptr rtt_types =
        RTT::types::TypeInfoRepository::Instance();

    VALUE result = rb_ary_new();
    vector<string> all_types = rtt_types->getTypes();
    for (vector<string>::iterator it = all_types.begin(); it != all_types.end(); ++it)
    {
        RTT::types::TypeInfo* ti = rtt_types->type(*it);
        vector<int> transports = ti->getTransportNames();
        if (find(transports.begin(), transports.end(), ORO_MQUEUE_PROTOCOL_ID) != transports.end())
            rb_ary_push(result, rb_str_new2(it->c_str()));
    }
    return result;
}
#endif

static VALUE orocos_no_blocking_calls_in_thread_set(VALUE self, VALUE thread)
{
    threadInterdiction = thread;
    return thread;
}

static VALUE orocos_no_blocking_calls_in_thread_get(VALUE self)
{
    return threadInterdiction;
}

extern "C" void Init_rorocos()
{
    mOrocos = rb_define_module("Orocos");
    mCORBA  = rb_define_module_under(mOrocos, "CORBA");
    eComError    = rb_define_class_under(mOrocos, "ComError", rb_eRuntimeError);
    eCORBA    = rb_define_class_under(mOrocos, "CORBAError", rb_eRuntimeError);
    eCORBAComError = rb_define_class_under(mCORBA, "ComError", eComError);
    eCORBATimeoutError = rb_define_class_under(mCORBA, "TimeoutError", eCORBA);
    eNotInitialized = rb_define_class_under(mOrocos, "NotInitialized", rb_eRuntimeError);
    eBlockingCallInForbiddenThread = rb_define_class_under(mOrocos, "BlockingCallInForbiddenThread", rb_eRuntimeError);

    rb_define_singleton_method(mOrocos, "load_standard_typekits", RUBY_METHOD_FUNC(orocos_load_standard_typekits), 0);
    rb_define_singleton_method(mOrocos, "load_rtt_plugin",  RUBY_METHOD_FUNC(orocos_load_rtt_plugin), 1);
    rb_define_singleton_method(mOrocos, "load_rtt_typekit", RUBY_METHOD_FUNC(orocos_load_rtt_typekit), 1);
    rb_define_singleton_method(mOrocos, "registered_type?", RUBY_METHOD_FUNC(orocos_registered_type_p), 1);
    rb_define_singleton_method(mOrocos, "do_typelib_type_for", RUBY_METHOD_FUNC(orocos_typelib_type_for), 1);
    rb_define_singleton_method(mOrocos, "no_blocking_calls_in_thread=", RUBY_METHOD_FUNC(orocos_no_blocking_calls_in_thread_set), 1);
    rb_define_singleton_method(mOrocos, "no_blocking_calls_in_thread", RUBY_METHOD_FUNC(orocos_no_blocking_calls_in_thread_get), 0);

    VALUE cTaskContextBase = rb_define_class_under(mOrocos, "TaskContextBase",rb_cObject);
    rb_const_set(cTaskContextBase, rb_intern("STATE_PRE_OPERATIONAL"),      INT2FIX(RTT::corba::CPreOperational));
    rb_const_set(cTaskContextBase, rb_intern("STATE_FATAL_ERROR"),          INT2FIX(RTT::corba::CFatalError));
    rb_const_set(cTaskContextBase, rb_intern("STATE_EXCEPTION"),            INT2FIX(RTT::corba::CException));
    rb_const_set(cTaskContextBase, rb_intern("STATE_STOPPED"),              INT2FIX(RTT::corba::CStopped));
    rb_const_set(cTaskContextBase, rb_intern("STATE_RUNNING"),              INT2FIX(RTT::corba::CRunning));
    rb_const_set(cTaskContextBase, rb_intern("STATE_RUNTIME_ERROR"),        INT2FIX(RTT::corba::CRunTimeError));

    rb_const_set(mOrocos, rb_intern("TRANSPORT_CORBA"), INT2FIX(ORO_CORBA_PROTOCOL_ID));

    cTaskContext = rb_define_class_under(mOrocos, "TaskContext", cTaskContextBase);

#ifdef HAS_MQUEUE
    VALUE mMQueue  = rb_define_module_under(mOrocos, "MQueue");
    rb_const_set(mOrocos, rb_intern("RTT_TRANSPORT_MQ_ID"),    INT2FIX(ORO_MQUEUE_PROTOCOL_ID));
    rb_define_singleton_method(mMQueue, "try_mq_open", RUBY_METHOD_FUNC(try_mq_open), 0);
    rb_define_singleton_method(mMQueue, "transportable_type_names", RUBY_METHOD_FUNC(mqueue_transportable_type_names), 0);
#endif

    cPort         = rb_define_class_under(mOrocos, "Port", rb_cObject);
    cOutputPort   = rb_define_class_under(mOrocos, "OutputPort", cPort);
    cInputPort    = rb_define_class_under(mOrocos, "InputPort", cPort);
    cPortAccess   = rb_define_class_under(mOrocos, "PortAccess", rb_cObject);
    eNotFound     = rb_define_class_under(mOrocos, "NotFound", rb_eRuntimeError);
    eStateTransitionFailed = rb_define_class_under(mOrocos, "StateTransitionFailed", rb_eRuntimeError);
    eConnectionFailed = rb_define_class_under(mOrocos, "ConnectionFailed", rb_eRuntimeError);

    rb_define_singleton_method(cTaskContext, "new", RUBY_METHOD_FUNC(task_context_create), -1);
    rb_define_method(cTaskContext, "do_real_name", RUBY_METHOD_FUNC(task_context_real_name), 0);
    rb_define_method(cTaskContext, "==", RUBY_METHOD_FUNC(task_context_equal_p), 1);
    rb_define_method(cTaskContext, "do_state", RUBY_METHOD_FUNC(task_context_state), 0);
    rb_define_method(cTaskContext, "do_configure", RUBY_METHOD_FUNC(task_context_configure), 0);
    rb_define_method(cTaskContext, "do_start", RUBY_METHOD_FUNC(task_context_start), 0);
    rb_define_method(cTaskContext, "do_reset_exception", RUBY_METHOD_FUNC(task_context_reset_exception), 0);
    rb_define_method(cTaskContext, "do_stop", RUBY_METHOD_FUNC(task_context_stop), 0);
    rb_define_method(cTaskContext, "do_cleanup", RUBY_METHOD_FUNC(task_context_cleanup), 0);
    rb_define_method(cTaskContext, "do_has_port?", RUBY_METHOD_FUNC(task_context_has_port_p), 1);
    rb_define_method(cTaskContext, "do_has_operation?", RUBY_METHOD_FUNC(task_context_has_operation_p), 1);
    rb_define_method(cTaskContext, "do_property_type_name", RUBY_METHOD_FUNC(task_context_property_type_name), 1);
    rb_define_method(cTaskContext, "do_attribute_type_name", RUBY_METHOD_FUNC(task_context_attribute_type_name), 1);
    rb_define_method(cTaskContext, "do_attribute_names", RUBY_METHOD_FUNC(task_context_attribute_names), 0);
    rb_define_method(cTaskContext, "do_property_names", RUBY_METHOD_FUNC(task_context_property_names), 0);
    rb_define_method(cTaskContext, "do_operation_names", RUBY_METHOD_FUNC(task_context_operation_names), 0);
    rb_define_method(cTaskContext, "do_port", RUBY_METHOD_FUNC(task_context_do_port), 2);
    rb_define_method(cTaskContext, "do_port_names", RUBY_METHOD_FUNC(task_context_port_names), 0);

    rb_define_method(cPort, "connected?", RUBY_METHOD_FUNC(port_connected_p), 0);
    rb_define_method(cPort, "do_disconnect_from", RUBY_METHOD_FUNC(do_port_disconnect_from), 1);
    rb_define_method(cPort, "do_disconnect_all", RUBY_METHOD_FUNC(do_port_disconnect_all), 0);
    rb_define_method(cPort, "do_create_stream", RUBY_METHOD_FUNC(do_port_create_stream), 1);
    rb_define_method(cPort, "do_remove_stream", RUBY_METHOD_FUNC(do_port_remove_stream), 1);
    rb_define_method(cOutputPort, "do_connect_to", RUBY_METHOD_FUNC(do_port_connect_to), 2);

    Orocos_init_CORBA();
#ifdef HAS_ROS
    Orocos_init_ROS(mOrocos, eComError);
#endif
    Orocos_init_data_handling(cTaskContext);
    Orocos_init_ruby_task_context(mOrocos, cTaskContext, cOutputPort, cInputPort);
    Orocos_init_methods();
}

