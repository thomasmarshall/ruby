require_relative '../spec_helper'
require_relative '../fixtures/classes'

describe "Socket::BasicSocket#recv_nonblock" do
  SocketSpecs.each_ip_protocol do |family, ip_address|
    before :each do
      @s1 = Socket.new(family, :DGRAM)
      @s2 = Socket.new(family, :DGRAM)
    end

    after :each do
      @s1.close unless @s1.closed?
      @s2.close unless @s2.closed?
    end

    platform_is_not :windows do
      describe 'using an unbound socket' do
        it 'raises an exception extending IO::WaitReadable' do
          -> { @s1.recv_nonblock(1) }.should raise_error(IO::WaitReadable)
        end
      end
    end

    it "raises an exception extending IO::WaitReadable if there's no data available" do
      @s1.bind(Socket.pack_sockaddr_in(0, ip_address))
      -> {
        @s1.recv_nonblock(5)
      }.should raise_error(IO::WaitReadable) { |e|
        platform_is_not :windows do
          e.should be_kind_of(Errno::EAGAIN)
        end
        platform_is :windows do
          e.should be_kind_of(Errno::EWOULDBLOCK)
        end
      }
    end

    it "returns :wait_readable with exception: false" do
      @s1.bind(Socket.pack_sockaddr_in(0, ip_address))
      @s1.recv_nonblock(5, exception: false).should == :wait_readable
    end

    it "receives data after it's ready" do
      @s1.bind(Socket.pack_sockaddr_in(0, ip_address))
      @s2.send("aaa", 0, @s1.getsockname)
      IO.select([@s1], nil, nil, 2)
      @s1.recv_nonblock(5).should == "aaa"
    end

    it "allows an output buffer as third argument" do
      @s1.bind(Socket.pack_sockaddr_in(0, ip_address))
      @s2.send("data", 0, @s1.getsockname)
      IO.select([@s1], nil, nil, 2)

      buffer = +"foo"
      @s1.recv_nonblock(5, 0, buffer).should.equal?(buffer)
      buffer.should == "data"
    end

    it "preserves the encoding of the given buffer" do
      @s1.bind(Socket.pack_sockaddr_in(0, ip_address))
      @s2.send("data", 0, @s1.getsockname)
      IO.select([@s1], nil, nil, 2)

      buffer = ''.encode(Encoding::ISO_8859_1)
      @s1.recv_nonblock(5, 0, buffer)
      buffer.encoding.should == Encoding::ISO_8859_1
    end

    it "does not block if there's no data available" do
      @s1.bind(Socket.pack_sockaddr_in(0, ip_address))
      @s2.send("a", 0, @s1.getsockname)
      IO.select([@s1], nil, nil, 2)
      @s1.recv_nonblock(1).should == "a"
      -> {
        @s1.recv_nonblock(5)
      }.should raise_error(IO::WaitReadable)
    end
  end

  SocketSpecs.each_ip_protocol do |family, ip_address|
    describe 'using a connected but not bound socket' do
      before do
        @server = Socket.new(family, :STREAM)
      end

      after do
        @server.close
      end

      it "raises Errno::ENOTCONN" do
        -> { @server.recv_nonblock(1) }.should raise_error { |e|
          [Errno::ENOTCONN, Errno::EINVAL].should.include?(e.class)
        }
        -> { @server.recv_nonblock(1, exception: false) }.should raise_error { |e|
          [Errno::ENOTCONN, Errno::EINVAL].should.include?(e.class)
        }
      end
    end
  end
end

describe "Socket::BasicSocket#recv_nonblock" do
  context "when recvfrom(2) returns 0 (if no messages are available to be received and the peer has performed an orderly shutdown)" do
    describe "stream socket" do
      before :each do
        @server = TCPServer.new('127.0.0.1', 0)
        @port = @server.addr[1]
      end

      after :each do
        @server.close unless @server.closed?
      end

      ruby_version_is ""..."3.3" do
        it "returns an empty String on a closed stream socket" do
          ready = false

          t = Thread.new do
            client = @server.accept

            Thread.pass while !ready
            begin
              client.recv_nonblock(10)
            rescue IO::EAGAINWaitReadable
              retry
            end
          ensure
            client.close if client
          end

          Thread.pass while t.status and t.status != "sleep"
          t.status.should_not be_nil

          socket = TCPSocket.new('127.0.0.1', @port)
          socket.close
          ready = true

          t.value.should == ""
        end
      end

      ruby_version_is "3.3" do
        it "returns nil on a closed stream socket" do
          ready = false

          t = Thread.new do
            client = @server.accept

            Thread.pass while !ready
            begin
              client.recv_nonblock(10)
            rescue IO::EAGAINWaitReadable
              retry
            end
          ensure
            client.close if client
          end

          Thread.pass while t.status and t.status != "sleep"
          t.status.should_not be_nil

          socket = TCPSocket.new('127.0.0.1', @port)
          socket.close
          ready = true

          t.value.should be_nil
        end
      end
    end
  end
end
