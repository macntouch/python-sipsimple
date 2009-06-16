# Copyright (C) 2008-2009 AG Projects. See LICENSE for details.
#

# classes

cdef class RTPTransport:
    cdef pjmedia_transport *_obj
    cdef pjmedia_transport *_wrapped_transport
    cdef pj_pool_t *_pool
    cdef int _af
    cdef object _local_rtp_addr
    cdef readonly object remote_rtp_port_sdp
    cdef readonly object remote_rtp_address_sdp
    cdef readonly object state
    cdef readonly object use_srtp
    cdef readonly object srtp_forced
    cdef readonly object use_ice
    cdef readonly object ice_stun_address
    cdef readonly object ice_stun_port
    cdef int _ice_active

    def __cinit__(self, *args, **kwargs):
        cdef object pool_name = "RTPTransport_%d" % id(self)
        cdef PJSIPUA ua = _get_ua()
        self._af = pj_AF_INET()
        self.state = "NULL"
        self._pool = pjsip_endpt_create_pool(ua._pjsip_endpoint._obj, pool_name, 4096, 4096)
        if self._pool == NULL:
            raise SIPCoreError("Could not allocate memory pool")

    def __init__(self, local_rtp_address=None, use_srtp=False, srtp_forced=False, use_ice=False,
                 ice_stun_address=None, ice_stun_port=PJ_STUN_PORT):
        cdef PJSIPUA ua = _get_ua()
        if self.state != "NULL":
            raise SIPCoreError("RTPTransport.__init__() was already called")
        if local_rtp_address is not None and not _is_valid_ip(self._af, local_rtp_address):
            raise ValueError("Not a valid IPv4 address: %s" % local_rtp_address)
        if ice_stun_address is not None and not _is_valid_ip(self._af, ice_stun_address):
            raise ValueError("Not a valid IPv4 address: %s" % ice_stun_address)
        self._local_rtp_addr = local_rtp_address
        self.use_srtp = use_srtp
        self.srtp_forced = srtp_forced
        self.use_ice = use_ice
        self.ice_stun_address = ice_stun_address
        self.ice_stun_port = ice_stun_port

    def __dealloc__(self):
        cdef PJSIPUA ua
        try:
            ua = _get_ua()
        except SIPCoreError:
            return
        if self.state in ["LOCAL", "ESTABLISHED"]:
            pjmedia_transport_media_stop(self._obj)
        if self._obj != NULL:
            pjmedia_transport_close(self._obj)
            if self._obj.type == PJMEDIA_TRANSPORT_TYPE_ICE:
                (<void **> (self._obj.name + 1))[0] = NULL
            if self._wrapped_transport != NULL:
                if self._wrapped_transport.type == PJMEDIA_TRANSPORT_TYPE_ICE:
                    (<void **> (self._obj.name + 1))[0] = NULL
                self._wrapped_transport = NULL
            self._obj = NULL
        if self._wrapped_transport != NULL:
            if self._wrapped_transport.type == PJMEDIA_TRANSPORT_TYPE_ICE:
                (<void **> (self._obj.name + 1))[0] = NULL
            pjmedia_transport_close(self._wrapped_transport)
        if self._pool != NULL:
            pjsip_endpt_release_pool(ua._pjsip_endpoint._obj, self._pool)

    cdef PJSIPUA _check_ua(self):
        cdef PJSIPUA ua
        try:
            ua = _get_ua()
            return ua
        except:
            self.state = "INVALID"
            self._obj = NULL
            self._wrapped_transport = NULL
            self._pool = NULL
            return None

    cdef int _get_info(self, pjmedia_transport_info *info) except -1:
        cdef int status
        pjmedia_transport_info_init(info)
        status = pjmedia_transport_get_info(self._obj, info)
        if status != 0:
            raise PJSIPError("Could not get transport info", status)
        return 0

    property local_rtp_port:

        def __get__(self):
            cdef pjmedia_transport_info info
            self._check_ua()
            if self.state in ["NULL", "WAIT_STUN", "INVALID"]:
                return None
            self._get_info(&info)
            if info.sock_info.rtp_addr_name.addr.sa_family != 0:
                return pj_sockaddr_get_port(&info.sock_info.rtp_addr_name)
            else:
                return None

    property local_rtp_address:

        def __get__(self):
            cdef pjmedia_transport_info info
            cdef char buf[PJ_INET6_ADDRSTRLEN]
            self._check_ua()
            if self.state in ["NULL", "WAIT_STUN", "INVALID"]:
                return self._local_rtp_addr
            self._get_info(&info)
            if pj_sockaddr_has_addr(&info.sock_info.rtp_addr_name):
                return pj_sockaddr_print(&info.sock_info.rtp_addr_name, buf, PJ_INET6_ADDRSTRLEN, 0)
            else:
                return None

    property remote_rtp_port_received:

        def __get__(self):
            cdef pjmedia_transport_info info
            self._check_ua()
            if self.state in ["NULL", "WAIT_STUN", "INVALID"]:
                return None
            self._get_info(&info)
            if info.src_rtp_name.addr.sa_family != 0:
                return pj_sockaddr_get_port(&info.src_rtp_name)
            else:
                return None

    property remote_rtp_address_received:

        def __get__(self):
            cdef pjmedia_transport_info info
            cdef char buf[PJ_INET6_ADDRSTRLEN]
            self._check_ua()
            if self.state in ["NULL", "WAIT_STUN", "INVALID"]:
                return None
            self._get_info(&info)
            if pj_sockaddr_has_addr(&info.src_rtp_name):
                return pj_sockaddr_print(&info.src_rtp_name, buf, PJ_INET6_ADDRSTRLEN, 0)
            else:
                return None

    property srtp_active:

        def __get__(self):
            cdef pjmedia_transport_info info
            cdef pjmedia_srtp_info *srtp_info
            cdef int i
            self._check_ua()
            if self.state in ["NULL", "WAIT_STUN", "INVALID"]:
                return False
            self._get_info(&info)
            for i from 0 <= i < info.specific_info_cnt:
                if info.spc_info[i].type == PJMEDIA_TRANSPORT_TYPE_SRTP:
                    srtp_info = <pjmedia_srtp_info *> info.spc_info[i].buffer
                    return bool(srtp_info.active)
            return False

    property ice_active:

        def __get__(self):
            return bool(self._ice_active)

    cdef int _update_local_sdp(self, BaseSDPSession local_sdp, int sdp_index, pjmedia_sdp_session *remote_sdp) except -1:
        cdef int status
        if sdp_index < 0:
            raise ValueError("sdp_index argument cannot be negative")
        if sdp_index >= local_sdp.get_sdp_session().media_count:
            raise ValueError("sdp_index argument out of range")
        status = pjmedia_transport_media_create(self._obj, self._pool, 0, remote_sdp, sdp_index)
        if status != 0:
            raise PJSIPError("Could not create media transport", status)
        status = pjmedia_transport_encode_sdp(self._obj, self._pool, local_sdp.get_sdp_session(), remote_sdp, sdp_index)
        if status != 0:
            raise PJSIPError("Could not update SDP for media transport", status)
        # TODO: work the changes back into the local_sdp object, but we don't need to do that yet.
        return 0

    def set_LOCAL(self, BaseSDPSession local_sdp, int sdp_index):
        self._check_ua()
        if local_sdp is None:
            raise SIPCoreError("local_sdp argument cannot be None")
        if self.state == "LOCAL":
            return
        if self.state != "INIT":
            raise SIPCoreError('set_LOCAL can only be called in the "INIT" state, current state is "%s"' % self.state)
        self._update_local_sdp(local_sdp, sdp_index, NULL)
        self.state = "LOCAL"

    def set_ESTABLISHED(self, BaseSDPSession local_sdp, BaseSDPSession remote_sdp, int sdp_index):
        cdef int status
        self._check_ua()
        if None in [local_sdp, remote_sdp]:
            raise SIPCoreError("SDP arguments cannot be None")
        if self.state == "ESTABLISHED":
            return
        if self.state not in ["INIT", "LOCAL"]:
            raise SIPCoreError('set_ESTABLISHED can only be called in the "INIT" and "LOCAL" states, ' +
                               'current state is "%s"' % self.state)
        if self.state == "INIT":
            self._update_local_sdp(local_sdp, sdp_index, remote_sdp.get_sdp_session())
        status = pjmedia_transport_media_start(self._obj, self._pool, local_sdp.get_sdp_session(), remote_sdp.get_sdp_session(), sdp_index)
        if status != 0:
            raise PJSIPError("Could not start media transport", status)
        if remote_sdp.media[sdp_index].connection is None:
            if remote_sdp.connection is not None:
                self.remote_rtp_address_sdp = remote_sdp.connection.address
        else:
            self.remote_rtp_address_sdp = remote_sdp.media[sdp_index].connection.address
        self.remote_rtp_port_sdp = remote_sdp.media[sdp_index].port
        self.state = "ESTABLISHED"

    def set_INIT(self):
        global _ice_cb
        cdef pj_str_t local_ip
        cdef pj_str_t *local_ip_p = &local_ip
        cdef pjmedia_srtp_setting srtp_setting
        cdef pj_ice_strans_cfg ice_cfg
        cdef int i
        cdef int status
        cdef PJSIPUA ua = self._check_ua()
        if self.state == "INIT":
            return
        if self.state in ["LOCAL", "ESTABLISHED"]:
            status = pjmedia_transport_media_stop(self._obj)
            if status != 0:
                raise PJSIPError("Could not stop media transport", status)
            self.remote_rtp_address_sdp = None
            self.remote_rtp_port_sdp = None
            self.state = "INIT"
        elif self.state == "NULL":
            if self._local_rtp_addr is None:
                local_ip_p = NULL
            else:
                _str_to_pj_str(self._local_rtp_addr, &local_ip)
            if self.use_ice:
                pj_ice_strans_cfg_default(&ice_cfg)
                ice_cfg.af = self._af
                pj_stun_config_init(&ice_cfg.stun_cfg, &ua._caching_pool._obj.factory, 0,
                                    pjmedia_endpt_get_ioqueue(ua._pjmedia_endpoint._obj),
                                    pjsip_endpt_get_timer_heap(ua._pjsip_endpoint._obj))
                if self.ice_stun_address is not None:
                    _str_to_pj_str(self.ice_stun_address, &ice_cfg.stun.server)
                    ice_cfg.stun.port = self.ice_stun_port
                # IIRC we can't choose the port for ICE
                status = pj_sockaddr_init(ice_cfg.af, &ice_cfg.stun.cfg.bound_addr, local_ip_p, 0)
                if status != 0:
                    raise PJSIPError("Could not init ICE bound address", status)
                status = pjmedia_ice_create2(ua._pjmedia_endpoint._obj, NULL, 2, &ice_cfg, &_ice_cb, 0, &self._obj)
                if status != 0:
                    raise PJSIPError("Could not create ICE media transport", status)
                (<void **> (self._obj.name + 1))[0] = <void *> self
            else:
                status = PJ_EBUG
                for i in xrange(ua._rtp_port_index, ua._rtp_port_index + ua._rtp_port_stop - ua._rtp_port_start, 2):
                    status = pjmedia_transport_udp_create3(ua._pjmedia_endpoint._obj, self._af, NULL, local_ip_p,
                                                           ua._rtp_port_start + i % (ua._rtp_port_stop -
                                                                                     ua._rtp_port_start),
                                                           0, &self._obj)
                    if status != PJ_ERRNO_START_SYS + EADDRINUSE:
                        ua._rtp_port_index = (i + 2) % (ua._rtp_port_stop - ua._rtp_port_start)
                        break
                if status != 0:
                    raise PJSIPError("Could not create UDP/RTP media transport", status)
            if self.use_srtp:
                self._wrapped_transport = self._obj
                self._obj = NULL
                pjmedia_srtp_setting_default(&srtp_setting)
                if self.srtp_forced:
                    srtp_setting.use = PJMEDIA_SRTP_MANDATORY
                status = pjmedia_transport_srtp_create(ua._pjmedia_endpoint._obj,
                                                       self._wrapped_transport, &srtp_setting, &self._obj)
                if status != 0:
                    pjmedia_transport_close(self._wrapped_transport)
                    self._wrapped_transport = NULL
                    raise PJSIPError("Could not create SRTP media transport", status)
            if not self.use_ice or self.ice_stun_address is None:
                self.state = "INIT"
                _add_event("RTPTransportDidInitialize", dict(obj=self))
            else:
                self.state = "WAIT_STUN"
        else:
            raise SIPCoreError('set_INIT can only be called in the "NULL", "LOCAL" and "ESTABLISHED" states, ' +
                               'current state is "%s"' % self.state)


cdef class AudioTransport:
    cdef pjmedia_stream *_obj
    cdef pjmedia_stream_info _stream_info
    cdef readonly RTPTransport transport
    cdef pj_pool_t *_pool
    cdef pjmedia_sdp_media *_local_media
    cdef unsigned int _conf_slot
    cdef readonly object direction
    cdef int _is_started
    cdef int _is_offer
    cdef unsigned int _vad
    cdef pj_timer_entry _timer
    cdef int _timer_active
    cdef unsigned int _packets_received
    cdef dict _cached_statistics

    def __cinit__(self, *args, **kwargs):
        cdef object pool_name = "AudioTransport_%d" % id(self)
        cdef PJSIPUA ua = _get_ua()
        self._pool = pjsip_endpt_create_pool(ua._pjsip_endpoint._obj, pool_name, 4096, 4096)
        if self._pool == NULL:
            raise SIPCoreError("Could not allocate memory pool")
        pj_timer_entry_init(&self._timer, 0, <void *> self, _AudioTransport_cb_check_rtp)

    def __init__(self, RTPTransport transport, BaseSDPSession remote_sdp=None,
                 int sdp_index=0, enable_silence_detection=True, list codecs=None):
        cdef pjmedia_transport_info info
        cdef pjmedia_sdp_session *local_sdp_c
        cdef SDPSession local_sdp
        cdef list global_codecs
        cdef int status
        cdef PJSIPUA ua = _get_ua()
        if self.transport is not None:
            raise SIPCoreError("AudioTransport.__init__() was already called")
        if transport is None:
            raise ValueError("transport argument cannot be None")
        if sdp_index < 0:
            raise ValueError("sdp_index argument cannot be negative")
        if transport.state != "INIT":
            raise SIPCoreError('RTPTransport object provided is not in the "INIT" state, but in the "%s" state' %
                               transport.state)
        self._vad = int(bool(enable_silence_detection))
        self.transport = transport
        transport._get_info(&info)
        if codecs is not None:
            global_codecs = ua._pjmedia_endpoint._get_codecs()
        try:
            if codecs is not None:
                ua._pjmedia_endpoint._set_codecs(codecs)
            status = pjmedia_endpt_create_sdp(ua._pjmedia_endpoint._obj, self._pool, 1, &info.sock_info, &local_sdp_c)
            if status != 0:
                raise PJSIPError("Could not generate SDP for audio session", status)
        finally:
            if codecs is not None:
                ua._pjmedia_endpoint._set_codecs(global_codecs)
        local_sdp = SDPSession_create(local_sdp_c)
        if remote_sdp is None:
            self._is_offer = 1
            self.transport.set_LOCAL(local_sdp, 0)
        else:
            self._is_offer = 0
            if sdp_index != 0:
                local_sdp.media = (sdp_index+1) * local_sdp.media
            self.transport.set_ESTABLISHED(local_sdp, remote_sdp, sdp_index)
        self._local_media = pjmedia_sdp_media_clone(self._pool, local_sdp.get_sdp_session().media[sdp_index])

    def __dealloc__(self):
        cdef PJSIPUA ua
        try:
            ua = _get_ua()
        except SIPCoreError:
            return
        if self._obj != NULL:
            self.stop()
        if self._pool != NULL:
            pjsip_endpt_release_pool(ua._pjsip_endpoint._obj, self._pool)

    cdef PJSIPUA _check_ua(self):
        cdef PJSIPUA ua
        try:
            ua = _get_ua()
            return ua
        except:
            self._obj = NULL
            self._pool = NULL
            return None

    property is_active:

        def __get__(self):
            self._check_ua()
            return bool(self._obj != NULL)

    property is_started:

        def __get__(self):
            return bool(self._is_started)

    property codec:

        def __get__(self):
            self._check_ua()
            if self._obj == NULL:
                return None
            else:
                return _pj_str_to_str(self._stream_info.fmt.encoding_name)

    property sample_rate:

        def __get__(self):
            self._check_ua()
            if self._obj == NULL:
                return None
            else:
                return self._stream_info.fmt.clock_rate

    property enable_silence_detection:

        def __get__(self):
            return bool(self._vad)

    property statistics:

        def __get__(self):
            cdef pjmedia_rtcp_stat stat
            cdef dict statistics = dict()
            cdef int status
            if self._cached_statistics is not None:
                return self._cached_statistics.copy()
            self._check_ua()
            if self._obj == NULL:
                return None
            status = pjmedia_stream_get_stat(self._obj, &stat)
            if status != 0:
                raise PJSIPError("Could not get RTP statistics", status)
            statistics["rtt"] = _pj_math_stat_to_dict(&stat.rtt)
            statistics["rx"] = _pjmedia_rtcp_stream_stat_to_dict(&stat.rx)
            statistics["tx"] = _pjmedia_rtcp_stream_stat_to_dict(&stat.tx)
            return statistics

    def get_local_media(self, is_offer, direction="sendrecv"):
        cdef SDPAttribute attr
        cdef SDPMedia local_media
        cdef object direction_attr
        if is_offer and direction not in ["sendrecv", "sendonly", "recvonly", "inactive"]:
            raise SIPCoreError("Unknown direction: %s" % direction)
        local_media = SDPMedia_create(self._local_media)
        local_media.attributes = [<object> attr for attr in local_media.attributes if attr.name not in ["sendrecv",
                                                                                                        "sendonly",
                                                                                                        "recvonly",
                                                                                                        "inactive"]]
        if is_offer:
            direction_attr = direction
        else:
            if self.direction is None or "recv" in self.direction:
                direction_attr = "sendrecv"
            else:
                direction_attr = "sendonly"
        local_media.attributes.append(SDPAttribute(direction_attr, ""))
        return local_media

    def start(self, BaseSDPSession local_sdp, BaseSDPSession remote_sdp, int sdp_index,
              int no_media_timeout=10, int media_check_interval=30):
        cdef pjmedia_port *media_port
        cdef pj_time_val no_media_pj
        cdef int status
        cdef object desired_state
        cdef PJSIPUA ua = _get_ua()
        if self._is_started:
            raise SIPCoreError("This AudioTransport was already started once")
        desired_state = ("LOCAL" if self._is_offer else "ESTABLISHED")
        if self.transport.state != desired_state:
            raise SIPCoreError('RTPTransport object provided is not in the "%s" state, but in the "%s" state' %
                               (desired_state, self.transport.state))
        if None in [local_sdp, remote_sdp]:
            raise ValueError("SDP arguments cannot be None")
        if sdp_index < 0:
            raise ValueError("sdp_index argument cannot be negative")
        if local_sdp.media[sdp_index].port == 0 or remote_sdp.media[sdp_index].port == 0:
            raise SIPCoreError("Cannot start a rejected audio stream")
        if no_media_timeout < 0:
            raise ValueError("no_media_timeout value cannot be negative")
        if media_check_interval < 0:
            raise ValueError("media_check_interval value cannot be negative")
        no_media_pj.sec = no_media_timeout
        no_media_pj.msec = 0
        if self.transport.state == "LOCAL":
            self.transport.set_ESTABLISHED(local_sdp, remote_sdp, sdp_index)
        status = pjmedia_stream_info_from_sdp(&self._stream_info, self._pool, ua._pjmedia_endpoint._obj,
                                              local_sdp.get_sdp_session(), remote_sdp.get_sdp_session(), sdp_index)
        if status != 0:
            raise PJSIPError("Could not parse SDP for audio session", status)
        if self._stream_info.param == NULL:
            raise SIPCoreError("Could not parse SDP for audio session")
        self._stream_info.param.setting.vad = self._vad
        status = pjmedia_stream_create(ua._pjmedia_endpoint._obj, self._pool, &self._stream_info,
                                       self.transport._obj, NULL, &self._obj)
        if status != 0:
            raise PJSIPError("Could not initialize RTP for audio session", status)
        status = pjmedia_stream_set_dtmf_callback(self._obj, _AudioTransport_cb_dtmf, <void *> self)
        if status != 0:
            pjmedia_stream_destroy(self._obj)
            self._obj = NULL
            raise PJSIPError("Could not set DTMF callback for audio session", status)
        status = pjmedia_stream_start(self._obj)
        if status != 0:
            pjmedia_stream_destroy(self._obj)
            self._obj = NULL
            raise PJSIPError("Could not start RTP for audio session", status)
        status = pjmedia_stream_get_port(self._obj, &media_port)
        if status != 0:
            pjmedia_stream_destroy(self._obj)
            self._obj = NULL
            raise PJSIPError("Could not get audio port for audio session", status)
        status = pjmedia_conf_add_port(ua._conf_bridge._obj, self._pool, media_port, NULL, &self._conf_slot)
        if status != 0:
            pjmedia_stream_destroy(self._obj)
            self._obj = NULL
            raise PJSIPError("Could not connect audio session to conference bridge", status)
        self.direction = "sendrecv"
        self.update_direction(local_sdp.media[sdp_index].get_direction())
        self._local_media = pjmedia_sdp_media_clone(self._pool, local_sdp.get_sdp_session().media[sdp_index])
        self._is_started = 1
        if no_media_pj.sec > 0:
            self._timer.id = media_check_interval
            status = pjsip_endpt_schedule_timer(ua._pjsip_endpoint._obj, &self._timer, &no_media_pj)
            if status == 0:
                self._timer_active = 1

    def stop(self):
        cdef PJSIPUA ua = self._check_ua()
        if self._timer_active:
            pjsip_endpt_cancel_timer(ua._pjsip_endpoint._obj, &self._timer)
            self._timer_active = 0
        if self._obj == NULL:
            return
        ua._conf_bridge._disconnect_slot(self._conf_slot)
        pjmedia_conf_remove_port(ua._conf_bridge._obj, self._conf_slot)
        self._cached_statistics = self.statistics
        pjmedia_stream_destroy(self._obj)
        self._obj = NULL
        self.transport.set_INIT()

    def update_direction(self, direction):
        cdef int status1 = 0
        cdef int status2 = 0
        self._check_ua()
        if self._obj == NULL:
            raise SIPCoreError("Stream is not active")
        if direction not in ["sendrecv", "sendonly", "recvonly", "inactive"]:
            raise SIPCoreError("Unknown direction: %s" % direction)
        if direction == self.direction:
            return
        if "send" in self.direction:
            if "send" not in direction:
                status1 = pjmedia_stream_pause(self._obj, PJMEDIA_DIR_ENCODING)
        else:
            if "send" in direction:
                status1 = pjmedia_stream_resume(self._obj, PJMEDIA_DIR_ENCODING)
        if "recv" in self.direction:
            if "recv" not in direction:
                status2 = pjmedia_stream_pause(self._obj, PJMEDIA_DIR_DECODING)
        else:
            if "recv" in direction:
                status2 = pjmedia_stream_resume(self._obj, PJMEDIA_DIR_DECODING)
        self.direction = direction
        if status1 != 0:
            raise SIPCoreError("Could not pause or resume encoding: %s" % _pj_status_to_str(status1))
        if status2 != 0:
            raise SIPCoreError("Could not pause or resume decoding: %s" % _pj_status_to_str(status2))

    def send_dtmf(self, digit):
        cdef pj_str_t digit_pj
        cdef int status
        cdef PJSIPUA ua = self._check_ua()
        if self._obj == NULL:
            raise SIPCoreError("Stream is not active")
        if len(digit) != 1 or digit not in "0123456789*#ABCD":
            raise SIPCoreError("Not a valid DTMF digit: %s" % digit)
        _str_to_pj_str(digit, &digit_pj)
        status = pjmedia_stream_dial_dtmf(self._obj, &digit_pj)
        if status != 0:
            raise PJSIPError("Could not send DTMF digit on audio stream", status)
        ua._conf_bridge._playback_dtmf(ord(digit))


# helper functions

cdef dict _pj_math_stat_to_dict(pj_math_stat *stat):
    cdef dict retval = dict()
    retval["count"] = stat.n
    retval["max"] = stat.max
    retval["min"] = stat.min
    retval["last"] = stat.last
    retval["avg"] = stat.mean
    return retval

cdef dict _pjmedia_rtcp_stream_stat_to_dict(pjmedia_rtcp_stream_stat *stream_stat):
    cdef dict retval = dict()
    retval["packets"] = stream_stat.pkt
    retval["bytes"] = stream_stat.bytes
    retval["packets_discarded"] = stream_stat.discard
    retval["packets_lost"] = stream_stat.loss
    retval["packets_reordered"] = stream_stat.reorder
    retval["packets_duplicate"] = stream_stat.dup
    retval["loss_period"] = _pj_math_stat_to_dict(&stream_stat.loss_period)
    retval["burst_loss"] = bool(stream_stat.loss_type.burst)
    retval["random_loss"] = bool(stream_stat.loss_type.random)
    retval["jitter"] = _pj_math_stat_to_dict(&stream_stat.jitter)
    return retval

# callback functions

cdef void _RTPTransport_cb_ice_complete(pjmedia_transport *tp, pj_ice_strans_op op, int status) with gil:
    cdef void *rtp_transport_void = NULL
    cdef RTPTransport rtp_transport
    cdef PJSIPUA ua
    try:
        ua = _get_ua()
    except:
        return
    try:
        if tp != NULL:
            rtp_transport_void = (<void **> (tp.name + 1))[0]
        if rtp_transport_void != NULL:
            rtp_transport = <object> rtp_transport_void
            if op == PJ_ICE_STRANS_OP_NEGOTIATION:
                if status == 0:
                    rtp_transport._ice_active = 1
                    _add_event("RTPTransportCompletedICENegotiation", dict(obj=rtp_transport, succeeded=True))
                else:
                    _add_event("RTPTransportCompletedICENegotiation", dict(obj=rtp_transport, succeeded=False,
                                                                           error=_pj_status_to_str(status)))
            elif op == PJ_ICE_STRANS_OP_INIT:
                if status == 0:
                    rtp_transport.state = "INIT"
                else:
                    rtp_transport.state = "INVALID"
                if status == 0:
                    _add_event("RTPTransportDidInitialize", dict(obj=rtp_transport))
                else:
                    _add_event("RTPTransportDidFail", dict(obj=rtp_transport, reason=_pj_status_to_str(status)))
    except:
        ua._handle_exception(1)

cdef void _AudioTransport_cb_dtmf(pjmedia_stream *stream, void *user_data, int digit) with gil:
    cdef AudioTransport audio_stream = <object> user_data
    cdef PJSIPUA ua
    try:
        ua = _get_ua()
    except:
        return
    try:
        _add_event("RTPAudioStreamGotDTMF", dict(obj=audio_stream, digit=chr(digit)))
        try:
            ua._conf_bridge._playback_dtmf(digit)
        except:
            ua._handle_exception(0)
    except:
        ua._handle_exception(1)

cdef void _AudioTransport_cb_check_rtp(pj_timer_heap_t *timer_heap, pj_timer_entry *entry) with gil:
    cdef PJSIPUA ua
    cdef AudioTransport audio_transport
    cdef pjmedia_rtcp_stat stat
    cdef pj_time_val no_media_pj
    cdef int status
    try:
        ua = _get_ua()
    except:
        return
    try:
        if entry.user_data != NULL:
            audio_transport = <object> entry.user_data
            audio_transport._timer_active = 0
            status = pjmedia_stream_get_stat(audio_transport._obj, &stat)
            if status == 0:
                if audio_transport._packets_received == stat.rx.pkt and audio_transport.direction == "sendrecv":
                    _add_event("RTPAudioTransportDidNotGetRTP", dict(obj=audio_transport, got_any=(stat.rx.pkt != 0)))
                audio_transport._packets_received = stat.rx.pkt
                no_media_pj.sec = entry.id
                no_media_pj.msec = 0
                if no_media_pj.sec > 0:
                    status = pjsip_endpt_schedule_timer(ua._pjsip_endpoint._obj, entry, &no_media_pj)
                    if status == 0:
                        audio_transport._timer_active = 1
    except:
        ua._handle_exception(1)

# globals

cdef pjmedia_ice_cb _ice_cb
_ice_cb.on_ice_complete = _RTPTransport_cb_ice_complete
