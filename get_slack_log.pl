#! /usr/bin/env perl

=pod

=encoding utf8

=head1 NAME

get_slack_log.pl

=head1 DESCRIPTION

Slack 指定チャンネルのログを取得し、日付毎の JSON ファイルとして保存します。

=head1 USAGE

`my_channel` というプライベートチャンネルについて 10 日前の日の 00:00 からログを取得して
JSON ファイルの保存する。

```bash
$ ./get_slack_log.pl --ch-name "my_channel" --ch_types private_channel --days 10
```

※ API トークンを書き込んだファイル `./token` が必要です。

=head1 SYNOPSIS

```bash
$ ./get_slack_log.pl
					--ch-name "<channel-name-on-slack>"
					[--days <days-to-oldest-day>]
					[--dest-dir </json/save/to/>]
					[--ch-types <comma-splited-types>]
```


=head1 OPTIONS

=head3 --ch-name <channel-name-on-slack>

必須パラメータ。チャンネル名。

=head3 --days <days-to-oldest-day>

オプション。遡る日数を指定するためのオプション。。

正確には取得開始時間を `<days-to-oldest-day>` 日前の 00:00:00 にセットする

デフォルトは指定なしになり Slack API の仕様に依存する


=head3 --dest-dir </json/save/to/>

オプション。JSON ファイルの書き出し先ディレクトリ指定。

=head3 --ch-types <comma-splited-types>

オプション。

対象チャンネルのチャンネルタイプをカンマ区切りで指定できる。
指摘できるのは以下 2 種のみ。

- `public_channel`
- `private_channel`

チャンネル名からチャンネルID を照合するとき、指定があると効率が上がる可能性がある。

デフォルトでは両方を探索対象にする。
詳細は [“conversations.list method | Slack”](https://api.slack.com/methods/conversations.list) を参照。

=cut

package SlackLogGetter;

use Moo;
use strictures 2;
use namespace::clean;

use LWP::Simple;
use URI;
use URI::QueryParam;
use JSON::XS;
use Scalar::Util qw/looks_like_number/;
use DateTime;

has api_token	=>
(
	is			=> 'rw',
	required	=> 1,
);

has ch_types =>
(
	is => 'rw',
	default	=> sub {return [qw/
								public_channel
								private_channel
							/]},
);

has ch_name =>
(
	is			=> 'ro',
	required	=> 1,
	default		=> undef
);

has time_zone =>
(
	is => 'rw',
	default	=> 'Asia/Tokyo'
);

has oldest_time =>
(
	is		=> 'rw',
	isa		=> sub{ die '"'.($_[0] // '').'" is NOT looks like number.' if( defined $_[0] && ! looks_like_number $_[0] ) },
	default	=> undef
);

has latest_time	=>
(
	is		=> 'rw',
	isa		=> sub{ die '"'.($_[0] // '').'" is NOT looks like number.' if( defined $_[0] && ! looks_like_number $_[0] ) },
	default	=> undef
);

has ua	=>
(
	is		=> 'rwp',
	lazy	=> 1,
	default	=> sub
	{
		return LWP::UserAgent->new;
	},
	isa	=> sub
	{
		$_[0]->isa('LWP::UserAgent');
	}
);

sub notice(@)
{
	map{
		warn $_."\n"
	} @_;
}

=head3 set_range_by_days( $days )

取得開始時間を `$days` 日前の 00:00:00 にセットします。

=cut

sub set_range_by_days
{
	my $self = shift @_;

	my $days = shift @_;

	my $now = DateTime->now( time_zone => $self->time_zone );
	my $dur = DateTime::Duration->new( days => $days );

	$now->subtract( $dur );

	$now->set_hour(0);
	$now->set_minute(0);
	$now->set_second(0);
	$now->set_nanosecond(0);

	$self->oldest_time( $now->epoch );
}


=head3 get_ch_info_from_ch_name( $ch_name )

実質的にはプラベートメソッド。パブリック命名なのは開発中の名残。

=cut

sub get_ch_info_from_ch_name
{
	my $self	= shift @_;

	my $name	= shift @_;

	my $uri = URI->new( 'https://slack.com/api/conversations.list' );
	$uri->query_param( token	=> $self->api_token				);
	$uri->query_param( types	=> join(',',@{$self->ch_types})	);
	$uri->query_param( exclude_archived	=> 'true'				);

	my $res = $self->ua->get( $uri );

	return undef unless( $res->is_success );

	my $json_str = $res->decoded_content;

	my $json = JSON::XS->new->decode( $json_str );

	for my $rec ( @{$json->{channels}} )
	{
		return $rec if( $rec->{name} eq $name );
	}

	return undef;
}


=head3 get_log_itelator( %attr )

ログ取得のためのイテレータ無名関数を返します。

イテレータを実行する毎に Slack の conversations.history API をコールし、
その結果オブジェクト（ハッシュリファレンス）を返します。

```perl
while( my $r = $ite->() )
{
	print $r->{messages}->[0]->{text}."\n";
}
```


=head4 MEMO : `conversations.history` の返す JSON 構造

{
	has_more	=> BOOLEAN
	is_limited	=> BOOLEAN
	messages	=>
	[
		{
			bot_id		=> "string"
			text		=> "string"
			ts			=> 'second(float numeric)'
			type		=> "string"
			username	=> "string"
		}
	]
	ok			=> BOOLEAN
	pin_count	=> INT?
	response_metadata	=>
	{
		next_cursor	=> 'next cursor'
	}

}

=cut


sub get_log_itelator
{
	my $self = shift @_;
	my %attr	= (
			ch_id				=> undef,
			items_per_page		=> undef,	# limit
			max_pages			=> undef,	# イテレーションする回数の指定
			@_
		);

	if( ! $attr{ch_id} )
	{
		my $ch_info = $self->get_ch_info_from_ch_name( $self->ch_name );

		$attr{ch_id} = $ch_info->{id};
	}
	
	die "ch_id not defined." if( ! $attr{ch_id} );

	my $uri = URI->new( 'https://slack.com/api/conversations.history' );
	$uri->query_param( token	=> $self->api_token				);
	$uri->query_param( channel	=> $attr{ch_id}					);

	$uri->query_param( limit	=> $attr{items_per_page}		) if( defined $attr{items_per_page} );
	$uri->query_param( latest	=> $self->latest_time			) if( defined $self->latest_time );
	$uri->query_param( oldest	=> $self->oldest_time			) if( defined $self->oldest_time );

	my $request_count	= 0;
	my $last_uri = $uri;
	my $has_more	= undef;
	my $next_cursor	= undef;

	return sub
	{
		my $new_uri = $last_uri->clone;

		return undef if(
			defined $attr{max_pages}
		 	&& $request_count > $attr{max_pages}
		 );

		if( $request_count > 0 )
		{
			return undef if(! $has_more );
			return undef if(! $next_cursor );

			$new_uri->query_param( cursor => $next_cursor );
		}

		notice '$request_count   : '.$request_count;
		notice '$attr{max_pages} : '.($attr{max_pages} // 'undef');
		notice '$next_cursor     : '.($next_cursor // '');
		notice '$has_more        : '.($has_more // '');
		
		my $res = $self->ua->get( $new_uri );

		$request_count ++;
		$last_uri	= $new_uri;

		unless( $res->is_success )
		{
			warn $res->message;
			return undef;
		}

		my $json_str	= $res->decoded_content;
		my $json		= JSON::XS->new->utf8->decode( $json_str );

		$has_more		= $json->{has_more} && 1;
		$next_cursor	= _fetch_with_key_path( $json, qw/response_metadata next_cursor/ );

		return $json;
	}
	
	
}

=head3 fetch_with_key_path( \%hash ,@keyPath )

`%hash` からキーパス方式で `@keyPath` に合致するキーパスに
アクセスし、その結果を返す。

存在しないキーパスの場合 undef を返す。

**USAGE**

```perl
my $node = fetch_with_key_path( \%hash ,qw/hoge moge 1/ )

# `$hash{hoge}->{moge}` が ArrayRef の時
# 	$hash{hoge}->{moge}->[1]
# `$hash{hoge}->{moge}` が HashRef の時
# 	$hash{hoge}->{moge}->{1}
# を返す
```

=cut

sub _fetch_with_key_path
{
	my $obj = shift @_;
	my @keyPath	= @_;

	while( @keyPath )
	{
		my $key = shift @keyPath;
		
		if( 'ARRAY' eq ref $obj
		 && $key =~ /^-{0,1}\d+$/)
		{
			$obj = $obj->[$key];
		}
		elsif( 'HASH' eq ref $obj )
		{
			$obj = $obj->{$key}
		}
		else
		{
			return undef;
		}
	}

	return $obj;
}


package main;

=pod

=encoding utf8

=head1 NAME

get_slack_log.pl

=head1 get_slack_log.pl

=cut

use strict;
use warnings;

use Path::Class;

use Data::Dumper;
$Data::Dumper::Terse	= 1;
$Data::Dumper::Sortkeys	= 1;
$Data::Dumper::Indent	= 2;

our %OPT = ();
{
	my %config = (
					 days		=> sub{ shift @ARGV },
					 'ch-name'	=> sub{ shift @ARGV },
					 'dest-dir'	=> sub{ shift @ARGV },
					 'ch-types'	=> sub{ [split(/,/, shift @ARGV )] }
				);

	parseARGV( \%OPT ,\%config );

	$OPT{'dest-dir'}	= './history_files' if( ! $OPT{'dest-dir'} );
}



our $TIME_ZONE = 'Asia/Tokyo';

main();

exit;

sub note(@)
{
	map
	{
		print STDERR $_."\n"
	} @_;
}

sub main
{
	note Dumper({'%OPT' => \%OPT  });

	my $token = undef;
	{
		my $body = file('./token')->slurp;
		( $token ) = $body =~ /(^xoxp-\d+.+$)/m;
		# note '$body : '.$body;
	}

	die "There are not API token in file 'token'." if( ! $token );
	
	my $s = SlackLogGetter->new(
				api_token	=> $token,
				ch_name		=> $OPT{'ch-name'}
				);

	$s->ch_types( $OPT{'ch-types'} ) if( $OPT{'ch-types'} );
	$s->set_range_by_days( $OPT{days} ) if( $OPT{days} );

	my $ite = $s->get_log_itelator();

	my %m = ();
	while( my $json = $ite->() )
	{
		append_time_stamp( $json->{messages} );

		note '-' x 40;
		# note '$json : '.Dumper( $json );
		note 'Here is '.@{$json->{messages}}.' messages.';
		note 'from '.$json->{messages}->[-1]->{time_stamp};
		note 'to   '.$json->{messages}->[0]->{time_stamp};

		# @{$json->{messages}} = sort {$a->{ts} <=> $b->{ts}} @{$json->{messages}};
		for my $rec ( reverse @{$json->{messages}})
		{
			my $dk = $rec->{_dts};

			$m{$dk} = [] if( ! ref $m{$dk} );

			# delete $rec->{_dts};

			push @{$m{$dk}} , $rec;
		}
	}

	# print JSON::XS->new->pretty->utf8->encode( \%m );
	my $serializer = JSON::XS->new->pretty->utf8;

	for my $date_key ( keys %m )
	{
		my $f = file(
					$OPT{'dest-dir'},
					$OPT{'ch-name'},
					$date_key.'.json'
				);

		$f->dir->mkpath( my $verbose = 1 );

		my $array = $m{$date_key};

		$f->spew( $serializer->encode( $array ) );
	}
}

sub append_time_stamp
{
	my $j = shift @_;

	for my $rec ( @$j )
	{
		next if( ! defined $rec->{ts} );

		my $dt = DateTime->from_epoch( epoch => $rec->{ts} ,time_zone => $TIME_ZONE );

		$rec->{time_stamp} = sprintf('%04d-%02d-%02d %02d:%02d:%02d',
										$dt->year,
										$dt->month,
										$dt->day,
										$dt->hour,
										$dt->minute,
										$dt->second
									);
		$rec->{_dts} = sprintf('%04d-%02d-%02d',$dt->year,$dt->month,$dt->day);
	}
}

=head2 parseARGV

コマンドライン引数をパースします。

=cut

sub parseARGV
{
	my $optRef	= shift @_;
	my $config	= shift @_;	# POD を参照
	
	my @allowOpts = keys %$config;

	$optRef->{'ARGV'} = [] if( ref $optRef->{'ARGV'} ne 'ARRAY' );

	while( @ARGV )
	{
		my $in	= shift @ARGV;
		my $opt	= undef;

		if( $in =~ /^-([^\-].*)/ )
		{
			# ショートオプション系
			$opt = $1;
		}
		elsif( $in =~ /^--(.+)/ )
		{
			# ロングオプション系
			$opt = $1;
		}
		else
		{
			# 通常の引数
			push @{$optRef->{'ARGV'}} ,$in;
			next;
		}

		die "Unknown option '$in'\nAvilable options are : \n"
		.Dumper([map{$_ = length $_ == 1 ? "-$_" : "--$_" } @allowOpts]) if( ! defined $opt
											|| ( @allowOpts && ! grep { $opt eq $_} @allowOpts ));

		if( $opt )
		{
			if( 'CODE' eq ref $config->{$opt} )
			{
				$optRef->{$opt} = $config->{$opt}->( $optRef );
			}
			else
			{
				$optRef->{$opt} = $config->{$opt};
			}
		}
		
	}
}


1;

__END__
