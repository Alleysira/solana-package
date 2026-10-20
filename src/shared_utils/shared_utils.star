# Shared utilities for the multi-client Solana Kurtosis package.
#
# Port-spec helpers that distinguish TCP (rpc) from UDP (gossip/tvu/tpu) ports.

TCP_PROTOCOL = "TCP"
UDP_PROTOCOL = "UDP"
HTTP_APPLICATION_PROTOCOL = "http"
NOT_PROVIDED_APPLICATION_PROTOCOL = ""
NOT_PROVIDED_WAIT = "not-provided-wait"


def new_port_spec(
    number,
    transport_protocol,
    application_protocol=NOT_PROVIDED_APPLICATION_PROTOCOL,
    wait=NOT_PROVIDED_WAIT,
):
    if wait == NOT_PROVIDED_WAIT:
        return PortSpec(
            number=number,
            transport_protocol=transport_protocol,
            application_protocol=application_protocol,
        )

    return PortSpec(
        number=number,
        transport_protocol=transport_protocol,
        application_protocol=application_protocol,
        wait=wait,
    )


def get_port_specs(port_assignments):
    """Build a Kurtosis port-spec dict from {port_id: PortSpec-like-or-number}.

    For backwards-compat, numbers default to TCP. Pass a (number, protocol)
    tuple to select UDP, e.g. {"gossip": (8001, UDP_PROTOCOL)}.
    """
    ports = {}
    for port_id, port in port_assignments.items():
        if type(port) == "tuple":
            number, proto = port
        else:
            number = port
            proto = TCP_PROTOCOL
        ports[port_id] = new_port_spec(number, proto)
    return ports
