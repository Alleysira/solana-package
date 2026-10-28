"""Structured acceptance, including real Firedancer leader blocks."""
constants = import_module("../package_io/constants.star")

def launch_verifier(plan, genesis_artifact, image):
    code = plan.upload_files(src="../../verification", name="network-verification-code")
    service = plan.add_service(
        name="network-verifier",
        config=ServiceConfig(
            image=image, entrypoint=["sleep"], cmd=["infinity"],
            files={"/data": genesis_artifact, "/opt/verification": code},
        ),
    )
    return struct(name="network-verifier", service=service)

def prepare_sig_snapshot(plan, verifier):
    plan.exec(
        service_name=verifier.name,
        recipe=ExecRecipe(command=["python3", "/opt/verification/verify_network.py", "prepare-sig"]),
        acceptable_codes=[0],
    )
    name = "sig-initial-snapshot"
    plan.store_service_files(name=name, service_name=verifier.name, src="/data/prepared-snapshot")
    return name

def wait_for_slots(plan, topology, slots_target, global_node_selectors={}, observation_seconds=600):
    # Capture actual binaries, independently of RPC version advertisements.
    for name, command in [
        (topology.bootstrap.name, ["bash", "-c", "export PATH=/opt/jito/bin:$PATH; agave-validator --version"]),
        (topology.joiner.name, ["bash", "-c", "export PATH=/opt/agave/bin:$PATH; agave-validator --version"]),
        (topology.firedancer.name, ["firedancer", "version"]),
        (topology.sig.name, ["bash", "-c", "kill -0 \"$(cat /var/lib/sig/sig.pid)\" && cat /opt/sig/BUILD-INFO"]),
    ]:
        plan.exec(service_name=name, recipe=ExecRecipe(command=command), acceptable_codes=[0])
    command = "python3 /opt/verification/verify_network.py observe --observation-seconds {0} --slots-target {1}".format(observation_seconds, slots_target)
    plan.exec(
        service_name=topology.verifier.name,
        recipe=ExecRecipe(command=["bash", "-c",
            "rm -f /data/verification/observer-exit-code; nohup bash -c '" + command
            + "; code=$?; echo $code > /data/verification/observer-exit-code' > /data/verification/observer.log 2>&1 </dev/null &",
        ]),
        acceptable_codes=[0],
    )
    plan.wait(
        service_name=topology.verifier.name,
        recipe=ExecRecipe(command=["test", "-f", "/data/verification/observer-exit-code"]),
        field="code", assertion="==", target_value=0,
        timeout=str(observation_seconds + 1200) + "s",
    )
    artifact = "network-verification-evidence"
    # Save failures as well as successes before enforcing the exit status.
    plan.store_service_files(
        name=artifact, service_name=topology.verifier.name, src="/data/verification",
    )
    plan.exec(
        service_name=topology.verifier.name,
        recipe=ExecRecipe(command=["bash", "-c",
            "cat /data/verification/observer.log; exit $(cat /data/verification/observer-exit-code)",
        ]),
        acceptable_codes=[0],
    )
    # A live container with an exited SIG child is not observer liveness.
    plan.exec(
        service_name=topology.sig.name,
        recipe=ExecRecipe(command=["bash", "-c", "kill -0 \"$(cat /var/lib/sig/sig.pid)\""]),
        acceptable_codes=[0],
    )
    result = plan.exec(
        service_name=topology.verifier.name,
        recipe=ExecRecipe(command=["python3", "-c",
            "import json; d=json.load(open('/data/verification/summary.json')); print(json.dumps({k:d[k] for k in ['result','topology','observationSeconds','sampleCount','transferCount','sigObserver']}))",
        ]),
        acceptable_codes=[0],
    )
    return struct(evidence_json=result["output"], evidence_artifact=artifact, slot_reached=True)
