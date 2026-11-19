#!/usr/bin/env bash
# Shared Ginkgo --skip patterns for OpenShift e2e (VM / metal and bastion).
# Sourced by run_tests.sh and run_tests-bastion.sh — edit only here.
#
# The following lists tests that are (currently) incompatible with the
# downstream setup.
#
# Usage:
#   # shellcheck source=./e2e-test-excludes.sh
#   source "${SCRIPT_DIR}/e2e-test-excludes.sh"
#
EXCLUDE_ARRAY=(
  'Routes.between.bgp.and.the.fabric.underlay.address.family.Unnumbered'
  'DHCP.underlay.lifecycle.removes.the.DHCP.interfaces.when.the.underlay.is.deleted'
  'reflects.type-2.routes.between.client.nodes.via.the.route.reflector'
  'assigns.each.underlay.port.a.unique.IPv6.link-local'
)
