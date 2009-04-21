#include "source.hpp"

using namespace simple_source;

source::source(std::string const& name)
    : sourceBase(name) {}

void source::updateHook()
{
    static int cycle = 0;
    _cycle.write(++cycle);
}







