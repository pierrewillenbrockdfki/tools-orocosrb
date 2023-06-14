#include <list>
#include <typeinfo>
#include <rtt/types/Types.hpp>

#include <rtt/transports/corba/TransportPlugin.hpp>
#include <rtt/transports/corba/CorbaLib.hpp>
#include <rtt/transports/corba/TaskContextServer.hpp>
#include <rtt/transports/corba/TaskContextProxy.hpp>
#include <rtt/transports/corba/CorbaDispatcher.hpp>

#include <rtt/Activity.hpp>
#include <boost/lexical_cast.hpp>

#include "corba.hh"
#include "rorocos.hh"
#include "lib/corba_name_service_client.hh"
#include <ruby/version.h>

using namespace CORBA;
using namespace std;
using namespace boost;
using namespace corba;

static VALUE cNameService;

CorbaAccess* CorbaAccess::the_instance = NULL;
void CorbaAccess::init(int argc, char* argv[])
{
    if (the_instance)
        return;
    the_instance = new CorbaAccess(argc, argv);
}
void CorbaAccess::deinit()
{
    delete the_instance;
    the_instance = NULL;
}

CorbaAccess::CorbaAccess(int argc, char* argv[])
{
    // First initialize the ORB. We use TaskContextProxy::InitORB as we will
    // have to create a servant for our local DataFlowInterface object.
    RTT::corba::TaskContextServer::InitOrb(argc, argv);
}

CorbaAccess::~CorbaAccess()
{
    RTT::corba::TaskContextServer::ShutdownOrb(true);
}

RTaskContext* CorbaAccess::createRTaskContext(std::string const& ior)
{
    std::auto_ptr<RTaskContext> new_context( new RTaskContext );
    // check if ior is a valid IOR if not an exception is thrown
    new_context->task = getCTaskContext(ior);
    new_context->main_service = new_context->task->getProvider("this");
    new_context->ports      = new_context->task->ports();
    CORBA::String_var nm =  new_context->task->getName();
    new_context->name = std::string(nm.in());
    return new_context.release();
}

RTT::corba::CTaskContext_var CorbaAccess::getCTaskContext(std::string const& ior)
{
    if(CORBA::is_nil(RTT::corba::ApplicationServer::orb))
        throw std::runtime_error("Corba is not initialized. Call Orocos.initialize first.");

    // Use the ior to create the task object reference,
    CORBA::Object_var task_object;
    try
    {
        task_object = RTT::corba::ApplicationServer::orb->string_to_object ( ior.c_str() );
    }
    catch(CORBA::SystemException &e)
    {
        throw InvalidIORError("given IOR " + ior + " is not valid");
    }

    // Then check we can actually access it
    RTT::corba::CTaskContext_var mtask;
    // Now downcast the object reference to the appropriate type
    mtask = RTT::corba::CTaskContext::_narrow (task_object.in());

    if(CORBA::is_nil( mtask ))
        throw std::runtime_error("cannot narrorw task context.");
    return mtask;
}

static VALUE corba_set_call_timeout(VALUE mod, VALUE duration)
{
    omniORB::setClientCallTimeout(NUM2INT(duration));
    return Qnil;
}

static VALUE corba_set_connect_timeout(VALUE mod, VALUE duration)
{
    omniORB::setClientConnectTimeout(NUM2INT(duration));
    return Qnil;
}

static void corba_deinit(void*)
{
    CorbaAccess::deinit();
    rb_iv_set(mCORBA, "@corba", Qnil);
    corbaAccess = Qnil;
}

/* call-seq:
 *   Orocos::CORBA.init => true or false
 *
 * Initializes the CORBA ORB and gets a reference to the local name server.
 * Returns true if a new connection has been made and false if the CORBA layer
 * was already initialized.
 *
 * It raises Orocos::CORBAError if either the ORB failed to initialize or the
 * name server cannot be found.
 */
static VALUE corba_init(VALUE mod)
{
    // Initialize only once ...
    if (!NIL_P(corbaAccess))
        return Qfalse;

    try {
        char const* argv[2] = { "bla", 0 };
        CorbaAccess::init(1, const_cast<char**>(argv));
        corbaAccess = Data_Wrap_Struct(rb_cObject, 0, corba_deinit, CorbaAccess::instance());
        rb_iv_set(mCORBA, "@corba", corbaAccess);
    } catch(CORBA::Exception& e) {
        rb_raise(eCORBA, "failed to contact the name server");
    }
    return Qtrue;
}

static VALUE corba_is_initialized(VALUE mod)
{ return NIL_P(corbaAccess) ? Qfalse : Qtrue; }

/* call-seq:
 *   Orocos::CORBA.transportable_type_names => name_list
 *
 * Returns an array of string that are the type names which can be transported
 * over the CORBA layer
 */
static VALUE corba_transportable_type_names(VALUE mod)
{
    RTT::types::TypeInfoRepository::shared_ptr rtt_types =
        RTT::types::TypeInfoRepository::Instance();

    VALUE result = rb_ary_new();
    vector<string> all_types = rtt_types->getTypes();
    for (vector<string>::iterator it = all_types.begin(); it != all_types.end(); ++it)
    {
        RTT::types::TypeInfo* ti = rtt_types->type(*it);
        vector<int> transports = ti->getTransportNames();
        if (find(transports.begin(), transports.end(), ORO_CORBA_PROTOCOL_ID) != transports.end())
            rb_ary_push(result, rb_str_new2(it->c_str()));
    }
    return result;
}

static VALUE name_service_create(int argc, VALUE *argv,VALUE klass)
{
    // all parametes are forwarded to ruby initialize
    std::string ip;
    std::string port;

    if(argc > 0)
    {
        if(TYPE(argv[0]) == T_STRING)
            ip = StringValueCStr(argv[0]);
    }
    if(argc > 1)
    {
        if(TYPE(argv[1]) == T_STRING)
            port = StringValueCStr(argv[1]);
    }

    std::auto_ptr<NameServiceClient> new_name_service(new NameServiceClient(ip,port));
    VALUE obj = simple_wrap(cNameService, new_name_service.release());
#if RUBY_API_VERSION_CODE >= 20700
    rb_obj_call_init_kw(obj,argc,argv,RB_PASS_CALLED_KEYWORDS);
#else
    rb_obj_call_init(obj,argc,argv);
#endif
    return obj;
}

static VALUE name_service_ip(VALUE self)
{
    NameServiceClient& name_service = get_wrapped<NameServiceClient>(self);
    return rb_str_new2(name_service.getIp().c_str());
}

static VALUE name_service_port(VALUE self)
{
    NameServiceClient& name_service = get_wrapped<NameServiceClient>(self);
    return rb_str_new2(name_service.getPort().c_str());
}

static VALUE name_service_reset(VALUE self,VALUE ip, VALUE port)
{
    std::string sip = StringValueCStr(ip);
    std::string sport = StringValueCStr(port);
    NameServiceClient& name_service = get_wrapped<NameServiceClient>(self);
    name_service.reset(sip,sport);
    return self;
}

void corba_must_be_initialized()
{
    if(CORBA::is_nil(RTT::corba::ApplicationServer::orb))
        rb_raise(eNotInitialized,"Corba is not initialized. Call Orocos.initialize first.");
}

static VALUE name_service_task_context_names(VALUE self)
{
    corba_must_be_initialized();

    NameServiceClient& name_service = get_wrapped<NameServiceClient>(self);
    std::vector<std::string> names;

    names = corba_blocking_fct_call_with_result(boost::bind(&NameServiceClient::getTaskContextNames,&name_service),
                              boost::bind(&NameServiceClient::abort,&name_service));

    VALUE result = rb_ary_new();
    for (vector<string>::const_iterator it = names.begin(); it != names.end(); ++it)
        rb_ary_push(result, rb_str_new2(it->c_str()));
    return result;
}


static VALUE name_service_unbind(VALUE self,VALUE task_name)
{
    corba_must_be_initialized();

    std::string name = StringValueCStr(task_name);
    NameServiceClient& name_service = get_wrapped<NameServiceClient>(self);
    bool result = corba_blocking_fct_call_with_result(boost::bind(&NameServiceClient::unbind,&name_service,name));
    return result ? Qtrue : Qfalse;
}

static VALUE name_service_validate(VALUE self)
{
    corba_must_be_initialized();

    NameServiceClient& name_service = get_wrapped<NameServiceClient>(self);
    corba_blocking_fct_call(boost::bind(&NameServiceClient::validate,&name_service));
    return Qnil;
}

static VALUE name_service_bind(VALUE self,VALUE task,VALUE task_name)
{
    corba_must_be_initialized();
    
    std::string name = StringValueCStr(task_name);
    NameServiceClient& name_service = get_wrapped<NameServiceClient>(self);
    RTaskContext& context = get_wrapped<RTaskContext>(task);
    CORBA::Object_var obj = CORBA::Object::_duplicate(context.task);
    corba_blocking_fct_call(boost::bind(&NameServiceClient::bind,&name_service,obj,name));
    return Qnil;
}

static VALUE name_service_ior(VALUE self,VALUE task_name)
{
    corba_must_be_initialized();

    std::string name = StringValueCStr(task_name);
    NameServiceClient& name_service = get_wrapped<NameServiceClient>(self);
    std::string ior = corba_blocking_fct_call_with_result(boost::bind(&NameServiceClient::getIOR,&name_service,name));
    return rb_str_new2(ior.c_str());
}


void Orocos_init_CORBA()
{
    VALUE mOrocos = rb_define_module("Orocos");
    rb_define_singleton_method(mCORBA, "initialized?", RUBY_METHOD_FUNC(corba_is_initialized), 0);
    rb_define_singleton_method(mCORBA, "do_init", RUBY_METHOD_FUNC(corba_init), 0);
    rb_define_singleton_method(mCORBA, "do_deinit", RUBY_METHOD_FUNC(corba_deinit), 0);
    rb_define_singleton_method(mCORBA, "do_call_timeout", RUBY_METHOD_FUNC(corba_set_call_timeout), 1);
    rb_define_singleton_method(mCORBA, "do_connect_timeout", RUBY_METHOD_FUNC(corba_set_connect_timeout), 1);
    rb_define_singleton_method(mCORBA, "transportable_type_names", RUBY_METHOD_FUNC(corba_transportable_type_names), 0);

    VALUE cNameServiceBase = rb_define_class_under(mOrocos, "NameServiceBase",rb_cObject);
    cNameService = rb_define_class_under(mCORBA, "NameService",cNameServiceBase);
    rb_define_singleton_method(cNameService, "new", RUBY_METHOD_FUNC(name_service_create), -1);
    rb_define_method(cNameService, "do_task_context_names", RUBY_METHOD_FUNC(name_service_task_context_names), 0);
    rb_define_method(cNameService, "do_ior", RUBY_METHOD_FUNC(name_service_ior), 1);
    rb_define_method(cNameService, "do_ip", RUBY_METHOD_FUNC(name_service_ip), 0);
    rb_define_method(cNameService, "do_port", RUBY_METHOD_FUNC(name_service_port), 0);
    rb_define_method(cNameService, "do_validate", RUBY_METHOD_FUNC(name_service_validate), 0);
    rb_define_method(cNameService, "do_reset", RUBY_METHOD_FUNC(name_service_reset), 2);
    rb_define_method(cNameService, "do_unbind", RUBY_METHOD_FUNC(name_service_unbind), 1);
    rb_define_method(cNameService, "do_bind", RUBY_METHOD_FUNC(name_service_bind), 2);
}
