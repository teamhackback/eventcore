/**
	Base class for BSD socket based driver implementations.

	See_also: `eventcore.drivers.select`, `eventcore.drivers.epoll`
*/
module eventcore.drivers.posix;
@safe: /*@nogc:*/ nothrow:

public import eventcore.driver;
import eventcore.drivers.timer;
import eventcore.internal.utils;

import std.socket : Address, AddressFamily, UnknownAddress;
version (Posix) {
	import core.sys.posix.netinet.in_;
	import core.sys.posix.netinet.tcp;
	import core.sys.posix.unistd : close, write;
	import core.stdc.errno : errno, EAGAIN, EINPROGRESS;
	import core.sys.posix.fcntl;
}
version (Windows) {
	import core.sys.windows.winsock2;
	alias EAGAIN = WSAEWOULDBLOCK;
}
version (linux) {
	extern (C) int eventfd(uint initval, int flags);
	enum EFD_NONBLOCK = 0x800;
}


private long currStdTime()
{
	import std.datetime : Clock;
	scope (failure) assert(false);
	return Clock.currStdTime;
}

abstract class PosixEventDriver : EventDriver {
	@safe: /*@nogc:*/ nothrow:

	private {
		ChoppedVector!FDSlot m_fds;
		size_t m_waiterCount = 0;
		bool m_exit = false;
		FD m_wakeupEvent;
	}

	protected this()
	{
		m_wakeupEvent = eventfd(0, EFD_NONBLOCK);
		initFD(m_wakeupEvent);
		registerFD(m_wakeupEvent, EventMask.read);
		//startNotify!(EventType.read)(m_wakeupEvent, null); // should already be caught by registerFD
	}

	mixin DefaultTimerImpl!();

	protected int maxFD() const { return cast(int)m_fds.length; }

	@property size_t waiterCount() const { return m_waiterCount; }

	final override ExitReason processEvents(Duration timeout)
	{
		import std.algorithm : min;
		import core.time : seconds;

		if (m_exit) {
			m_exit = false;
			return ExitReason.exited;
		}

		if (!waiterCount) return ExitReason.outOfWaiters;

		bool got_events;

		if (timeout <= 0.seconds) {
			got_events = doProcessEvents(0.seconds);
			processTimers(currStdTime);
		} else {
			long now = currStdTime;
			do {
				auto nextto = min(getNextTimeout(now), timeout);
				got_events = doProcessEvents(nextto);
				long prev_step = now;
				now = currStdTime;
				processTimers(now);
				if (timeout != Duration.max)
					timeout -= (now - prev_step).hnsecs;
			} while (timeout > 0.seconds && !m_exit && !got_events);
		}

		if (m_exit) {
			m_exit = false;
			return ExitReason.exited;
		}
		if (!waiterCount) return ExitReason.outOfWaiters;
		if (got_events) return ExitReason.idle;
		return ExitReason.timeout;
	}

	final override void exit()
	{
		m_exit = true;
		int one = 1;
		() @trusted { write(m_wakeupEvent, &one, one.sizeof); } ();
	}

	protected abstract bool doProcessEvents(Duration dur);
	abstract void dispose();

	final override StreamSocketFD connectStream(scope Address address, ConnectCallback on_connect)
	{
		auto sock = cast(StreamSocketFD)createSocket(address.addressFamily);
		if (sock == -1) return StreamSocketFD.invalid;

		void invalidateSocket() @nogc @trusted nothrow { closeSocket(sock); sock = StreamSocketFD.invalid; }

		scope bind_addr = new UnknownAddress;
		bind_addr.name.sa_family = cast(ushort)address.addressFamily;
		bind_addr.name.sa_data[] = 0;
		if (() @trusted { return bind(sock, bind_addr.name, bind_addr.nameLen); } () != 0) {
			invalidateSocket();
			on_connect(sock, ConnectStatus.bindFailure);
			return sock;
		}

		registerFD(sock, EventMask.read|EventMask.write|EventMask.status);

		auto ret = () @trusted { return connect(sock, address.name, address.nameLen); } ();
		if (ret == 0) {
			on_connect(sock, ConnectStatus.connected);
		} else {
			auto err = getSocketError();
			if (err == EINPROGRESS) {
				with (m_fds[sock]) {
					connectCallback = on_connect;
				}
				startNotify!(EventType.write)(sock, &onConnect);
			} else {
				unregisterFD(sock);
				invalidateSocket();
				on_connect(sock, ConnectStatus.unknownError);
			}
		}

		initFD(sock);

		return sock;
	}

	private void onConnect(FD sock)
	{
		m_fds[sock].connectCallback(cast(StreamSocketFD)sock, ConnectStatus.connected);
	}

	private void onConnectError(FD sock)
	{
		// FIXME: determine the correct kind of error!
		m_fds[sock].connectCallback(cast(StreamSocketFD)sock, ConnectStatus.refused);
	}

	final override StreamListenSocketFD listenStream(scope Address address, AcceptCallback on_accept)
	{
		auto sock = cast(StreamListenSocketFD)createSocket(address.addressFamily);

		void invalidateSocket() @nogc @trusted nothrow { closeSocket(sock); sock = StreamSocketFD.invalid; }

		() @trusted {
			int tmp_reuse = 1;
			// FIXME: error handling!
			if (setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &tmp_reuse, tmp_reuse.sizeof) != 0) {
				invalidateSocket();
			} else if (bind(sock, address.name, address.nameLen) != 0) {
				invalidateSocket();
			} else if (listen(sock, 128) != 0) {
				invalidateSocket();
			} else { scope (failure) assert(false); import std.stdio; writeln("Success!"); }
		} ();

		if (on_accept && sock != StreamListenSocketFD.invalid)
			waitForConnections(sock, on_accept);

		return sock;
	}

	final override void waitForConnections(StreamListenSocketFD sock, AcceptCallback on_accept)
	{
		registerFD(sock, EventMask.read);
		initFD(sock);
		m_fds[sock].acceptCallback = on_accept;
		startNotify!(EventType.read)(sock, &onAccept);
	}

	private void onAccept(FD listenfd)
	{
		scope addr = new UnknownAddress;
		foreach (i; 0 .. 20) {
			int sockfd;
			version (Windows) int addr_len = addr.nameLen;
			else uint addr_len = addr.nameLen;
			() @trusted { sockfd = accept(listenfd, addr.name, &addr_len); } ();
			if (sockfd == -1) break;

			setSocketNonBlocking(cast(SocketFD)sockfd);
			auto fd = cast(StreamSocketFD)sockfd;
			registerFD(fd, EventMask.read|EventMask.write|EventMask.status);
			initFD(fd);
			//print("accept %d", sockfd);
			m_fds[listenfd].acceptCallback(cast(StreamListenSocketFD)listenfd, fd);
		}
	}

	final override void setTCPNoDelay(StreamSocketFD socket, bool enable)
	{
		int opt = enable;
		() @trusted { setsockopt(socket, IPPROTO_TCP, TCP_NODELAY, cast(char*)&opt, opt.sizeof); } ();
	}

	final override void readSocket(StreamSocketFD socket, ubyte[] buffer, IOMode mode, IOCallback on_read_finish)
	{
		sizediff_t ret;
		() @trusted { ret = recv(socket, buffer.ptr, buffer.length, 0); } ();

		if (ret < 0) {
			auto err = getSocketError();
			if (err != EAGAIN) {
				print("sock error %s!", err);
				on_read_finish(socket, IOStatus.error, 0);
				return;
			}
		}

		size_t bytes_read = 0;

		if (ret == 0) {
			on_read_finish(socket, IOStatus.disconnected, 0);
			return;
		}

		if (ret < 0 && mode == IOMode.immediate) {
			on_read_finish(socket, IOStatus.wouldBlock, 0);
			return;
		}

		if (ret > 0) {
			bytes_read += ret;
			buffer = buffer[bytes_read .. $];
			if (mode != IOMode.all || buffer.length == 0) {
				on_read_finish(socket, IOStatus.ok, bytes_read);
				return;
			}
		}

		with (m_fds[socket]) {
			readCallback = on_read_finish;
			readMode = mode;
			bytesRead = ret > 0 ? ret : 0;
			readBuffer = buffer;
		}

		setNotifyCallback!(EventType.read)(socket, &onSocketRead);
	}

	private void onSocketRead(FD fd)
	{
		auto slot = &m_fds[fd];
		auto socket = cast(StreamSocketFD)fd;

		void finalize()(IOStatus status)
		{
			setNotifyCallback!(EventType.read)(socket, null);
			//m_fds[fd].readBuffer = null;
			slot.readCallback(socket, status, slot.bytesRead);
		}

		sizediff_t ret;
		() @trusted { ret = recv(socket, slot.readBuffer.ptr, slot.readBuffer.length, 0); } ();
		if (ret < 0) {
			auto err = getSocketError();
			if (err != EAGAIN) {
				finalize(IOStatus.error);
				return;
			}
		}

		if (ret == 0) {
			finalize(IOStatus.disconnected);
			return;
		}

		if (ret > 0) {
			slot.bytesRead += ret;
			slot.readBuffer = slot.readBuffer[ret .. $];
			if (slot.readMode != IOMode.all || slot.readBuffer.length == 0) {
				finalize(IOStatus.ok);
				return;
			}
		}
	}

	final override void writeSocket(StreamSocketFD socket, const(ubyte)[] buffer, IOMode mode, IOCallback on_write_finish)
	{
		sizediff_t ret;
		() @trusted { ret = send(socket, buffer.ptr, buffer.length, 0); } ();

		if (ret < 0) {
			auto err = getSocketError();
			if (err != EAGAIN) {
				on_write_finish(socket, IOStatus.error, 0);
				return;
			}
		}

		size_t bytes_written = 0;

		if (ret == 0) {
			on_write_finish(socket, IOStatus.disconnected, 0);
			return;
		}

		if (ret < 0 && mode == IOMode.immediate) {
			on_write_finish(socket, IOStatus.wouldBlock, 0);
			return;
		}

		if (ret > 0) {
			bytes_written += ret;
			buffer = buffer[ret .. $];
			if (mode != IOMode.all || buffer.length == 0) {
				on_write_finish(socket, IOStatus.ok, bytes_written);
				return;
			}
		}

		with (m_fds[socket]) {
			writeCallback = on_write_finish;
			writeMode = mode;
			bytesWritten = ret > 0 ? ret : 0;
			writeBuffer = buffer;
		}

		setNotifyCallback!(EventType.write)(socket, &onSocketWrite);
	}

	private void onSocketWrite(FD fd)
	{
		auto slot = &m_fds[fd];
		auto socket = cast(StreamSocketFD)fd;

		sizediff_t ret;
		() @trusted { ret = send(socket, slot.writeBuffer.ptr, slot.writeBuffer.length, 0); } ();

		if (ret < 0) {
			auto err = getSocketError();
			if (err != EAGAIN) {
				setNotifyCallback!(EventType.write)(socket, null);
				slot.readCallback(socket, IOStatus.error, slot.bytesRead);
				return;
			}
		}

		if (ret == 0) {
			setNotifyCallback!(EventType.write)(socket, null);
			slot.writeCallback(cast(StreamSocketFD)socket, IOStatus.disconnected, slot.bytesWritten);
			return;
		}

		if (ret > 0) {
			slot.bytesWritten += ret;
			slot.writeBuffer = slot.writeBuffer[ret .. $];
			if (slot.writeMode != IOMode.all || slot.writeBuffer.length == 0) {
				setNotifyCallback!(EventType.write)(socket, null);
				slot.writeCallback(cast(StreamSocketFD)socket, IOStatus.ok, slot.bytesWritten);
				return;
			}
		}
	}

	final override void waitSocketData(StreamSocketFD socket, IOCallback on_data_available)
	{
		sizediff_t ret;
		ubyte dummy;
		() @trusted { ret = recv(socket, &dummy, 1, MSG_PEEK); } ();

		if (ret < 0) {
			auto err = getSocketError();
			if (err != EAGAIN) {
				on_data_available(socket, IOStatus.error, 0);
				return;
			}
		}

		size_t bytes_read = 0;

		if (ret == 0) {
			on_data_available(socket, IOStatus.disconnected, 0);
			return;
		}

		if (ret > 0) {
			on_data_available(socket, IOStatus.ok, 0);
			return;
		}

		with (m_fds[socket]) {
			readCallback = on_data_available;
			readMode = IOMode.once;
			bytesRead = 0;
			readBuffer = null;
		}

		setNotifyCallback!(EventType.read)(socket, &onSocketDataAvailable);
	}

	private void onSocketDataAvailable(FD fd)
	{
		auto slot = &m_fds[fd];
		auto socket = cast(StreamSocketFD)fd;

		void finalize()(IOStatus status)
		{
			setNotifyCallback!(EventType.read)(socket, null);
			//m_fds[fd].readBuffer = null;
			slot.readCallback(socket, status, 0);
		}

		sizediff_t ret;
		ubyte tmp;
		() @trusted { ret = recv(socket, &tmp, 1, MSG_PEEK); } ();
		if (ret < 0) {
			auto err = getSocketError();
			if (err != EAGAIN) finalize(IOStatus.error);
		} else finalize(ret ? IOStatus.ok : IOStatus.disconnected);
	}

	final override void shutdownSocket(StreamSocketFD socket, bool shut_read, bool shut_write)
	{
		// TODO!
	}

	final override EventID createEvent()
	{
		auto id = cast(EventID)eventfd(0, EFD_NONBLOCK);
		initFD(id);
		registerFD(id, EventMask.read);
		startNotify!(EventType.read)(id, &onEvent);
		return id;
	}

	final override void triggerEvent(EventID event, bool notify_all = true)
	{
		foreach (w; m_fds[event].waiters.consume)
			w(event);
	}

	final override void triggerEvent(EventID event, bool notify_all = true)
	shared {
		/*int one = 1;
		if (notify_all) atomicStore(m_fds[event].triggerAll, true);
		() @trusted { write(event, &one, one.sizeof); } ();*/
		assert(false);
	}

	final override EventWaitID waitForEvent(EventID event, EventCallback on_event)
	{
		//return m_fds[event].waiters.put(on_event);
		assert(false);
	}

	final override void stopWaitingForEvent(EventID event, EventWaitID wait_id)
	{
		assert(false);
		//m_fds[event].waiters.remove(wait_id);
	}

	private void onEvent(FD event)
	{
		assert(false);
		/*auto all = atomicLoad(m_fds[event].triggerAll);
		atomicStore(m_fds[event].triggerAll, false);
		triggerEvent(cast(EventID)event, all);*/
	}

	final override void addRef(SocketFD fd)
	{
		auto pfd = &m_fds[fd];
		assert(pfd.refCount > 0);
		m_fds[fd].refCount++;
	}

	final override void addRef(FileFD descriptor)
	{
		assert(false);
	}

	final override void addRef(EventID descriptor)
	{
		auto pfd = &m_fds[descriptor];
		assert(pfd.refCount > 0);
		m_fds[descriptor].refCount++;
	}

	final override void releaseRef(SocketFD fd)
	{
		auto pfd = &m_fds[fd];
		assert(pfd.refCount > 0);
		if (--m_fds[fd].refCount == 0) {
			unregisterFD(fd);
			clearFD(fd);
			closeSocket(fd);
		}
	}

	final override void releaseRef(FileFD descriptor)
	{
		assert(false);
	}
	
	final override void releaseRef(TimerID descriptor)
	{
		assert(false);
	}
	
	final override void releaseRef(EventID descriptor)
	{
		auto pfd = &m_fds[descriptor];
		assert(pfd.refCount > 0);
		if (--m_fds[descriptor].refCount == 0) {
			unregisterFD(descriptor);
			clearFD(descriptor);
			close(descriptor);
		}
	}
	

	/// Registers the FD for general notification reception.
	protected abstract void registerFD(FD fd, EventMask mask);
	/// Unregisters the FD for general notification reception.
	protected abstract void unregisterFD(FD fd);
	/// Updates the event mask to use for listening for notifications.
	protected abstract void updateFD(FD fd, EventMask mask);

	final protected void enumerateFDs(EventType evt)(scope FDEnumerateCallback del)
	{
		// TODO: optimize!
		foreach (i; 0 .. cast(int)m_fds.length)
			if (m_fds[i].callback[evt])
				del(cast(FD)i);
	}

	final protected void notify(EventType evt)(FD fd)
	{
		//assert(m_fds[fd].callback[evt] !is null, "Notifying FD which is not listening for event.");
		if (m_fds[fd].callback[evt])
			m_fds[fd].callback[evt](fd);
	}

	private void startNotify(EventType evt)(FD fd, FDSlotCallback callback)
	{
		//assert(m_fds[fd].callback[evt] is null, "Waiting for event which is already being waited for.");
		m_fds[fd].callback[evt] = callback;
		m_waiterCount++;
		updateFD(fd, m_fds[fd].eventMask);
	}

	private void stopNotify(EventType evt)(FD fd)
	{
		//ssert(m_fds[fd].callback[evt] !is null, "Stopping waiting for event which is not being waited for.");
		m_fds[fd].callback[evt] = null;
		m_waiterCount--;
		updateFD(fd, m_fds[fd].eventMask);
	}

	private void setNotifyCallback(EventType evt)(FD fd, FDSlotCallback callback)
	{
		assert((callback !is null) != (m_fds[fd].callback[evt] !is null));
		m_fds[fd].callback[evt] = callback;
	}

	private SocketFD createSocket(AddressFamily family)
	{
		int sock;
		() @trusted { sock = socket(family, SOCK_STREAM, 0); } ();
		if (sock == -1) return SocketFD.invalid;
		setSocketNonBlocking(cast(SocketFD)sock);
		return cast(SocketFD)sock;
	}

	private void initFD(FD fd)
	{
		m_fds[fd].refCount = 1;
	}

	private void clearFD(FD fd)
	{
		m_fds[fd] = FDSlot.init;
	}
}

alias FDEnumerateCallback = void delegate(FD);

alias FDSlotCallback = void delegate(FD);

private struct FDSlot {
	import eventcore.internal.consumablequeue;

	FDSlotCallback[EventType.max+1] callback;

	uint refCount;

	size_t bytesRead;
	ubyte[] readBuffer;
	IOMode readMode;
	IOCallback readCallback;

	size_t bytesWritten;
	const(ubyte)[] writeBuffer;
	IOMode writeMode;
	IOCallback writeCallback;

	ConnectCallback connectCallback;
	AcceptCallback acceptCallback;
	ConsumableQueue!EventCallback waiters;

	@property EventMask eventMask() const nothrow {
		EventMask ret = cast(EventMask)0;
		if (callback[EventType.read] !is null) ret |= EventMask.read;
		if (callback[EventType.write] !is null) ret |= EventMask.write;
		if (callback[EventType.status] !is null) ret |= EventMask.status;
		return ret;
	}
}

enum EventType {
	read,
	write,
	status
}

enum EventMask {
	read = 1<<0,
	write = 1<<1,
	status = 1<<2
}

private void closeSocket(SocketFD sockfd)
@nogc {
	version (Windows) () @trusted { closesocket(sockfd); } ();
	else close(sockfd);
}

private void setSocketNonBlocking(SocketFD sockfd)
{
	version (Windows) {
		size_t enable = 1;
		() @trusted { ioctlsocket(sockfd, FIONBIO, &enable); } ();
	} else {
		() @trusted { fcntl(sockfd, F_SETFL, O_NONBLOCK, 1); } ();
	}
}

private int getSocketError()
@nogc {
	version (Windows) return WSAGetLastError();
	else return errno;
}


/*version (Windows) {
	import std.c.windows.windows;
	import std.c.windows.winsock;

	alias EWOULDBLOCK = WSAEWOULDBLOCK;

	extern(System) DWORD FormatMessageW(DWORD dwFlags, const(void)* lpSource, DWORD dwMessageId, DWORD dwLanguageId, LPWSTR lpBuffer, DWORD nSize, void* Arguments);

	class WSAErrorException : Exception {
		int error;

		this(string message, string file = __FILE__, size_t line = __LINE__)
		{
			error = WSAGetLastError();
			this(message, error, file, line);
		}

		this(string message, int error, string file = __FILE__, size_t line = __LINE__)
		{
			import std.string : format;
			ushort* errmsg;
			FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER|FORMAT_MESSAGE_FROM_SYSTEM|FORMAT_MESSAGE_IGNORE_INSERTS,
						   null, error, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT), cast(LPWSTR)&errmsg, 0, null);
			size_t len = 0;
			while (errmsg[len]) len++;
			auto errmsgd = (cast(wchar[])errmsg[0 .. len]).idup;
			LocalFree(errmsg);
			super(format("%s: %s (%s)", message, errmsgd, error), file, line);
		}
	}

	alias SystemSocketException = WSAErrorException;
} else {
	import std.exception : ErrnoException;
	alias SystemSocketException = ErrnoException;
}

T socketEnforce(T)(T value, lazy string msg = null, string file = __FILE__, size_t line = __LINE__)
{
	import std.exception : enforceEx;
	return enforceEx!SystemSocketException(value, msg, file, line);
}*/