package RemoteBrowser;
use strict;
use Moo 2;
no warnings 'experimental::signatures';
use feature 'signatures';
use IO::Async;
use Future;
Net::Async::WebSocket::Server->VERSION(0.12); # fixes some errors with masked frames

use JSON 'encode_json', 'decode_json';

use Scalar::Util 'weaken';

# This should go into ::Transport so we can support AnyEvent directly as well
# later
use IO::Async::Loop;
use Net::Async::WebSocket::Server;

use Data::Dumper;

has 'loop' => is => 'lazy', default => sub { IO::Async::Loop->new() };
has 'port' => is => 'ro', default => 3000;
has 'connection' => is => 'rw';

has 'outstanding' => is => 'ro', default => sub { {} };

#sub connect( $self, $handler, $url, $logger=undef ) {
#    $logger ||= sub{};
#    die "Got an undefined endpoint" unless defined $url;
#    weaken $handler;
#
#    my $client;
#    $client = Net::Async::WebSocket::Client->new(
#        # Kick off the continous polling
#        on_frame => sub {
#            my( $connection, $message )=@_;
#			use Data::Dumper;
#			warn Dumper \@_;
#            #$handler->on_response( $connection, $message )
#        },
#    );
#    $self->loop->add( $client );
#    $self->{connection} ||= $client;
#
#    $logger->('debug',"Connecting to $url");
#    $client->connect( url => $url, on_connected => sub {
#        $logger->('info',"Connected to $url");
#    })->catch(sub{
#        #require Data::Dumper;
#        #warn "caught";
#        #warn Data::Dumper::Dumper( \@_ );
#        Future->fail( @_ );
#    });
#}

my $messageIndex = 0;

my $k;
sub listen( $self, $port=$self->port ) {
    my $client_connected = $self->future;
    my $server; $server = Net::Async::WebSocket::Server->new(
        on_client => sub {
            my ( undef, $client ) = @_;
		    $self->connection( $client );

            $client->configure(
               on_text_frame => sub {
                 my ( $s, $frame ) = @_;
  				 if( length( $frame ) == 4 and $frame eq 'ping' ) { # yeah, hand-rolled pings
                     $self->connection->send_text_frame( 'pong' );
                     return
                  };
  				 my $p = decode_json( $frame );
  				 if( $p->{clientType}) {
                      # initial client connected

  					 $self->send( {"success" => JSON::true() } );
                     $k = $self->setup_connection( $client );
                     $client_connected->done($p);
                  } elsif( $p->{response} ) {
                      $self->handle_response( $p );

  				 } else {
                     print "Unknown, ignored\n";
                     warn Dumper $frame;
  				     # Try to send a command
  					 #$self->send( {"success" => JSON::true() } ); # await browser.tabs.update({ "url": "about:blank" })' );
                      # browser.tabs.update({ url: 'https://intoli.com/blog' })
  					 #$self->send( {"channel" => "evaluateInBackground", data => {'asyncFunction' => 'async (args) => (browser.tabs.create(args))', args =>[{ "url" => "https://datenzoo.de" }]}, messageIndex => $i++, response => JSON::false() } );
                      # get tab id
  					 #$self->send( {"channel" => "evaluateInContent", data => {'asyncFunction' => 'async (args) => (window.alert(args))', args =>["Hello"]}, response => JSON::false(), id => 1 } );
  				 };
               },
            );

        }
    );

    $self->loop->add( $server );

    $server->listen(
        service => $port,
    );


    $client_connected
};

sub setup_connection( $self, $connection ) {
    $self->send( {"channel" => "evaluateInBackground", data => {'asyncFunction' => 'async (args) => (browser.tabs.create(args))', args =>[{ "url" => "https://datenzoo.de" }]}, response => JSON::false() } )
    ->then( sub {
        my( $data ) = @_;
        #warn "Running in page";
        warn Dumper $data;
        $self->send( {"channel" => "evaluateInContent", data => {tabId => $data->{result}->{id}, 'asyncFunction' => 'async (args) => (window.alert(args))', args =>["Hello"]}, response => JSON::false() } );
    })->catch( sub {
         warn "*** Error:";
         warn Dumper \@_;
    }); # await browser.tabs.update({ "url": "about:blank" })' );
}

sub handle_response( $self, $response ) {
    print Dumper $response;
    my $id = $response->{messageIndex};

    my $inReplyTo = delete $self->outstanding->{ $id };
    if( $inReplyTo ) {
        print sprintf "[ %03d - %s ] <= %s\n", $id, $inReplyTo, Dumper $response->{data};
        eval { $inReplyTo->done( $response->{data} ); };
        warn $@ if $@;
    } else {
        print "Don't know recipient for [$id]\n";
    };
}

sub send( $self, $message ) {
    my $idx = $messageIndex++;
    $message->{messageIndex} = $idx;
    my $res = $self->outstanding->{$idx} = $self->future;
    my $payload = encode_json( $message );
    print sprintf "[ %03d - %s ] => %s\n", $idx, $res, $payload;
    $self->send_text( $payload );
    $res
}

sub send_text( $self, $message ) {
    $self->connection->send_text_frame( $message )
}

sub close( $self ) {
    my $c = delete $self->{connection};
    $c->finish
        if $c;
    delete $self->{ua};
}

sub future( $self ) {
    $self->loop->new_future;
}

sub connectionUrl( $self ) {
    sprintf 'ws://localhost:%d', $self->port;
};

package main;
use strict;

my $b = RemoteBrowser->new();
my $url = $b->connectionUrl;
$b->listen()->get;

my $sessionId = 666;
my $browserUrl = "file:///?remoteBrowserUrl=${url}&remoteBrowserSessionId=${sessionId}";

print "$browserUrl\n";

#$b->connect(undef, 'ws://localhost:8000')->get;

$b->loop->run;

# add contentScript to retrieve the DOM of a page
# (and other window properties)