/* IEEE 1364-2005 §27.33.1.1: cbStmt runs immediately before the indicated
 * statement. §27.33.1.3 applies the callback to a module's statements.
 * The registration is made from a running calltf, so no callback exists
 * when the initial process starts. Values seen before its watched blocking
 * assignments must be 0, 1 and 3; removing the registration suppresses the
 * intervening assignment. No source delay separates any of these actions.
 * A variable is an invalid cbStmt target; the module is its legal neighbour.
 */
//! inherited IEEE 1364-2005 27.33.1.1
//! inherited IEEE 1364-2005 27.33.1.3
//! inherited-reject IEEE 1364-2005 27.33.1.1

#include "vpi_user.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static vpiHandle statement_callback, variable;
static unsigned calls, arms, disarms;
static const int expected[] = {0, 1, 3};

static void require(int condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "audit_stmt_registration_during_call: %s\n", message);
        exit(1);
    }
}

static PLI_INT32 before_statement(p_cb_data callback)
{
    s_vpi_value value;
    if (vpi_get(vpiType, callback->obj) != vpiAssignment) return 0;
    require(vpi_compare_objects(vpi_handle(vpiLhs, callback->obj), variable),
            "callback identifies the wrong assignment");
    require(calls < sizeof expected / sizeof expected[0], "unexpected assignment callback");
    value.format = vpiIntVal;
    vpi_get_value(variable, &value);
    require(value.value.integer == expected[calls], "callback did not precede the expected assignment");
    ++calls;
    return 0;
}

static PLI_INT32 arm(PLI_BYTE8 *unused)
{
    s_cb_data callback;
    s_vpi_time time;
    vpiHandle module;
    (void)unused;
    require(statement_callback == NULL, "registration already armed");
    variable = vpi_handle_by_name("audit_stmt_registration_during_call.q", NULL);
    module = vpi_handle_by_name("audit_stmt_registration_during_call", NULL);
    require(variable != NULL && module != NULL, "design handles missing");
    memset(&callback, 0, sizeof callback);
    memset(&time, 0, sizeof time);
    time.type = vpiSuppressTime;
    callback.reason = cbStmt;
    callback.cb_rtn = before_statement;
    callback.time = &time;
    callback.obj = variable;
    require(vpi_register_cb(&callback) == NULL, "a variable is not a statement target");
    require(vpi_chk_error(NULL) != 0, "invalid target has no diagnostic");
    callback.obj = module;
    statement_callback = vpi_register_cb(&callback);
    require(statement_callback != NULL && vpi_chk_error(NULL) == 0, "module registration failed");
    ++arms;
    return 0;
}

static PLI_INT32 disarm(PLI_BYTE8 *unused)
{
    (void)unused;
    require(vpi_remove_cb(statement_callback) == 1, "removal failed");
    statement_callback = NULL;
    ++disarms;
    return 0;
}

static PLI_INT32 finish(p_cb_data unused)
{
    s_vpi_value value;
    (void)unused;
    require(arms == 2 && disarms == 1, "system tasks did not run");
    require(calls == sizeof expected / sizeof expected[0], "missing assignment callbacks");
    value.format = vpiIntVal;
    vpi_get_value(variable, &value);
    require(value.value.integer == 4, "callback changed final HDL behavior");
    puts("stmt-registration: before=0,1,3 final=4");
    return 0;
}

static void register_application(void)
{
    s_vpi_systf_data task;
    s_cb_data callback;
    memset(&task, 0, sizeof task);
    task.type = vpiSysTask;
    task.tfname = "$arm";
    task.calltf = arm;
    require(vpi_register_systf(&task) != NULL, "$arm registration failed");
    task.tfname = "$disarm";
    task.calltf = disarm;
    require(vpi_register_systf(&task) != NULL, "$disarm registration failed");
    memset(&callback, 0, sizeof callback);
    callback.reason = cbEndOfSimulation;
    callback.cb_rtn = finish;
    require(vpi_register_cb(&callback) != NULL, "final callback registration failed");
}

void (*vlog_startup_routines[])(void) = {register_application, NULL};
