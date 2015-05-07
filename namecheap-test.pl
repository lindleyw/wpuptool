use WWW::Namecheap::API;
    
my $api = WWW::Namecheap::API->new(
#    System => 'test',
    ApiUser => 'wlindley1',
    ApiKey => '455eae41b9524b4fbf3e5eb0d3dfa371',
    DefaultIp => '74.207.252.189',
    );
    
my $result = $api->domain->check(Domains => ['example.com']);
    
if ($result->{'example.com'}) {
        # $api->domain->create(
        #     DomainName => 'example.com',
        #     Years => 1,
        #     Registrant => {
        #         OrganizationName => 'Foo Bar Inc.',
        #         FirstName => 'Joe',
        #         LastName => 'Manager',
        #         Address1 => '123 Fake Street',
        #         City => 'Univille',
        #         StateProvince => 'SD',
        #         PostalCode => '12345',
        #         Country => 'US',
        #         Phone => '+1.2125551212',
        #         EmailAddress => 'joe@example.com',
        #     },
	#     );
}

use Data::Dumper;

print Dumper($api);
