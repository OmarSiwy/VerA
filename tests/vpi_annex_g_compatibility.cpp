/* Compile-only C++ client for the existing public interface. */
#include "vpi_user.h"
#include "vpi_user.h"
#include <type_traits>
static_assert(std::is_same<decltype(s_vpi_vecval::aval), PLI_INT32>::value,
              "Annex G signed vector word");
static_assert(std::is_same<decltype(&vpi_handle_by_name),
                          vpiHandle (*)(PLI_BYTE8 *, vpiHandle)>::value,
              "Annex G mutable-name declaration");
/* A writable name is portable in both C and C++; no literal mutation needed. */
vpiHandle lookup_existing_interface() {
    PLI_BYTE8 name[] = "top";
    return vpi_handle_by_name(name, nullptr);
}
