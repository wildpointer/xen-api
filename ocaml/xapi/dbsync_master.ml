(*
 * Copyright (C) 2006-2009 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
(**
 * @group Main Loop and Start-up
 *)
 
module D=Debug.Make(struct let name="dbsync" end)
open D

open Client

(* Synchronising code which is specific to the master *)


(* create pool record (if master and not one already there) *)
let create_pool_record ~__context =
	let pools = Db.Pool.get_all ~__context in
	if pools=[] then
		Db.Pool.create ~__context ~ref:(Ref.make()) ~uuid:(Uuid.to_string (Uuid.make_uuid()))
			~name_label:"" ~name_description:"" ~master:(Helpers.get_localhost ~__context) 
			~default_SR:Ref.null ~suspend_image_SR:Ref.null ~crash_dump_SR:Ref.null
			~ha_enabled:false ~ha_configuration:[] ~ha_statefiles:[]
			~ha_host_failures_to_tolerate:0L ~ha_plan_exists_for:0L ~ha_allow_overcommit:false ~ha_overcommitted:false ~blobs:[] ~tags:[] ~gui_config:[] ~health_check_config:[]
			~wlb_url:"" ~wlb_username:"" ~wlb_password:Ref.null ~wlb_enabled:false ~wlb_verify_cert:false
			~redo_log_enabled:false ~redo_log_vdi:Ref.null ~vswitch_controller:"" ~restrictions:[]
			~current_operations:[] ~allowed_operations:[]
			~other_config:[
				Xapi_globs.memory_ratio_hvm;
				Xapi_globs.memory_ratio_pv;
			]
			~ha_cluster_stack:"xhad"
			~guest_agent_config:[]
			~cpu_info:[]

let set_master_ip ~__context =
  let ip =
    match (Helpers.get_management_ip_addr ~__context) with
	Some ip -> ip
      | None ->
	  (error "Cannot read master IP address. Check the control interface has an IP address"; "") in
  let host = Helpers.get_localhost ~__context in
    Db.Host.set_address ~__context ~self:host ~value:ip

(* NB the master doesn't use the heartbeat mechanism to track its own liveness so we
   must make sure that live starts out as true because it will never be updated. *)
let set_master_live ~__context = 
  let host = Helpers.get_localhost ~__context in
  let metrics = Db.Host.get_metrics ~__context ~self:host in
  debug "Setting Host_metrics.live to true for localhost";
  Db.Host_metrics.set_live ~__context ~self:metrics ~value:true

let set_master_pool_reference ~__context =
	let pool = Helpers.get_pool ~__context in
	Db.Pool.set_master ~__context ~self:pool ~value:(Helpers.get_localhost ~__context)

let refresh_console_urls ~__context =
  List.iter
    (fun console ->
       Helpers.log_exn_continue (Printf.sprintf "Updating console: %s" (Ref.string_of console))
	 (fun () ->
	    let vm = Db.Console.get_VM ~__context ~self:console in
	    let host = Db.VM.get_resident_on ~__context ~self:vm in
	    let address = Db.Host.get_address ~__context ~self:host in
	    let url_should_be = Printf.sprintf "https://%s%s?ref=%s" address Constants.console_uri (Ref.string_of console) in
	    Db.Console.set_location ~__context ~self:console ~value:url_should_be
	 ) ()
    ) (Db.Console.get_all ~__context)

(** CA-15449: after a pool restore database VMs which were running on slaves now have dangling resident_on fields.
    If these are control domains we destroy them, otherwise we reset them to Halted. *)
let reset_vms_running_on_missing_hosts ~__context =
  List.iter (fun vm ->
	       let vm_r = Db.VM.get_record ~__context ~self:vm in
	       let valid_resident_on = Db.is_valid_ref __context vm_r.API.vM_resident_on in
	       if not valid_resident_on then begin
		 if vm_r.API.vM_is_control_domain then begin
		   info "Deleting control domain VM uuid '%s' ecause VM.resident_on refers to a Host which is nolonger in the Pool" vm_r.API.vM_uuid;
		   Db.VM.destroy ~__context ~self:vm
		 end else if vm_r.API.vM_power_state = `Running then begin
		   let msg = Printf.sprintf "Resetting VM uuid '%s' to Halted because VM.resident_on refers to a Host which is nolonger in the Pool" vm_r.API.vM_uuid in
		   info "%s" msg;
		   Helpers.log_exn_continue msg (fun () -> Xapi_vm_lifecycle.force_state_reset ~__context ~self:vm ~value:`Halted) ()
		 end
	       end) (Db.VM.get_all ~__context)

(** Release 'locks' on VMs in the Halted state: ie {VBD,VIF}.{currently_attached,reserved}
    Note that the {allowed,current}_operations fields are non-persistent so blanked on *master* startup (not slave)
    No allowed_operations are recomputed here: this work is performed later in a non-critical thread.
 *)
let release_locks ~__context =
  (* non-running VMs should have their VBD.current_operations cleared: *)
  let vms = List.filter (fun self -> Db.VM.get_power_state ~__context ~self = `Halted) (Db.VM.get_all ~__context) in
  List.iter (fun vm -> 
	       List.iter (fun self -> 
			    Xapi_vbd_helpers.clear_current_operations ~__context ~self)
		 (Db.VM.get_VBDs ~__context ~self:vm)) vms;
  (* Resets the current operations of all Halted VMs *)
  List.iter (fun self -> Xapi_vm_lifecycle.force_state_reset ~__context ~self ~value:`Halted) vms;
  (* All VMs should have their scheduled_to_be_resident_on field cleared *)
  List.iter (fun self -> Db.VM.set_scheduled_to_be_resident_on ~__context ~self ~value:Ref.null)
    (Db.VM.get_all ~__context)

let create_tools_sr __context = 
	Helpers.call_api_functions ~__context (fun rpc session_id ->
		(* Creates a new SR and PBD record *)
		(* N.b. dbsync_slave is called _before_ this, so we can't rely on the PBD creating code in there
			 to make the PBD for the shared tools SR *)
		let create_magic_sr name description _type content_type device_config sr_other_config shared =
			let sr =
				try
					(* Check if it already exists *)
					List.hd (Client.SR.get_by_name_label rpc session_id name)
				with _ ->
					begin
						let sr =
							Client.SR.introduce ~rpc ~session_id ~uuid:(Uuid.to_string (Uuid.make_uuid()))
								~name_label:name
								~name_description:description
								~_type ~content_type ~shared ~sm_config:[] in
						Client.SR.set_other_config ~rpc ~session_id ~self:sr ~value:sr_other_config;
						Db.SR.set_is_tools_sr ~__context ~self:sr ~value:true;
						sr
					end in
			(* Master has created this shared SR, lets make PBDs for all of the slaves too. Nb. device-config is same for all hosts *)
			let hosts = Db.Host.get_all ~__context in
			List.iter (fun host -> ignore (Create_storage.maybe_create_pbd rpc session_id sr device_config host)) hosts
		in

		(* Create XenSource Tools ISO, if an SR with this name is not already there: *)
		let tools_srs = List.filter (fun self -> Db.SR.get_is_tools_sr ~__context ~self) (Db.SR.get_all ~__context) in
		if tools_srs = [] then
			create_magic_sr
				(Xapi_globs.tools_sr_name ())
				(Xapi_globs.tools_sr_description ())
				"iso" "iso"
				["path", !Xapi_globs.tools_sr_dir; (* for ffs *)
				 "location", !Xapi_globs.tools_sr_dir; (* for legacy iso *)
				 "legacy_mode", "true"]
				[Xapi_globs.xensource_internal, "true";
				 Xapi_globs.tools_sr_tag, "true";
				 Xapi_globs.i18n_key, "xenserver-tools";
				 (Xapi_globs.i18n_original_value_prefix ^ "name_label"),
				 Xapi_globs.tools_sr_name ();
				 (Xapi_globs.i18n_original_value_prefix ^ "name_description"),
				 Xapi_globs.tools_sr_description ()]
				true
	)

let create_tools_sr_noexn __context = Helpers.log_exn_continue "creating tools SR" create_tools_sr __context

let ensure_vm_metrics_records_exist __context =
  List.iter (fun vm ->
				 let m = Db.VM.get_metrics ~__context ~self:vm in
				 if not(Db.is_valid_ref __context m) then begin
				   info "Regenerating missing VM_metrics record for VM %s" (Ref.string_of vm);
				   let m = Ref.make () in
				   let uuid = Uuid.to_string (Uuid.make_uuid ()) in
				   Db.VM_metrics.create ~__context ~ref:m ~uuid
					   ~vCPUs_number:0L
					   ~vCPUs_utilisation:[] ~memory_actual:0L
					   ~vCPUs_CPU:[]
					   ~vCPUs_params:[]
					   ~vCPUs_flags:[]
					   ~start_time:Date.never
					   ~install_time:Date.never
					   ~state: []
					   ~last_updated:(Date.of_float 0.)
					   ~other_config:[];
				   Db.VM.set_metrics ~__context ~self:vm ~value:m
				 end
			) (Db.VM.get_all __context)

let ensure_vm_metrics_records_exist_noexn __context = Helpers.log_exn_continue "ensuring VM_metrics flags exist" ensure_vm_metrics_records_exist __context

let destroy_invalid_pool_patches ~__context =
	let is_valid_pool_patch patch =
		(* If patch has been applied to at least one host, then it is valid. *)
		if (Db.Pool_patch.get_host_patches ~__context ~self:patch) <> [] then true
		(* If patch hasn't been applied to any host, but we can still apply it, then it is valid. *)
		(* File needs to exist in the master's filesystem for us to be able to apply it. *)
		else if (Sys.file_exists (Db.Pool_patch.get_filename ~__context ~self:patch)) then true
		else false
	in
	let pool_patches = Db.Pool_patch.get_all ~__context in
	List.iter
		(fun patch ->
			if not (is_valid_pool_patch patch)
			then Db.Pool_patch.destroy ~__context ~self:patch)
		pool_patches

(* Update the database to reflect current state. Called for both start of day and after
   an agent restart. *)
let update_env __context =
  debug "creating root user";
  Create_misc.create_root_user ~__context;

  debug "creating pool record";
  create_pool_record ~__context;
  set_master_pool_reference ~__context;
  set_master_ip ~__context;
  set_master_live ~__context;

  (* CA-15449: when we restore from backup we end up with Hosts being forgotten and VMs
     marked as running with dangling resident_on references. We delete the control domains
     and reset the rest to Halted. *)
  reset_vms_running_on_missing_hosts ~__context;

  (* Resets all Halted VMs to a known good state *)
  release_locks ~__context;
  (* Cancel tasks that were running on the master - by setting host=None we consider all tasks
     in the db for cancelling *)
  Cancel_tasks.cancel_tasks_on_host ~__context ~host_opt:None;
  (* Update the SM plugin table *)
  Storage_access.on_xapi_start ~__context;

  create_tools_sr_noexn __context;

	ensure_vm_metrics_records_exist_noexn __context;
	destroy_invalid_pool_patches ~__context
