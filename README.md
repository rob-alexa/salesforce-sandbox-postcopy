# sandbox-postcopy
*implements Salesforce's SandboxPostCopy and Batchable interfaces to modify email addresses on completion of a sandbox refresh*

In Salesforce's Spring '16 release, the Run Script After Sandbox Creation and Refresh feature was released. It allows developers to create an Apex class that implements the SandboxPostCopy interface and specify the class on the Sandbox Options screen (pictured in the screenshot at the top of this post).

One use for this is to modify email addresses that are included in records as part of refreshing a partial copy or full sandbox. Salesforce automatically modifies sandbox user email addresses to the format of emailname=domain.com@example.com but doesn't do so for other types of records (such as leads, contacts, or queues). Leaving these unmodified could end up in undesired email messages being sent to real prospects, customers, or employees.

I found some code published by Steve O'Neal that uses SandboxPostCopy in combination with the Batchable interface to modify sandbox email addresses in a way that can handle large numbers of records. I made a few modifications to Steve's code, including:

* changing the batch classes so the test class will work in production orgs (not just sandboxes)
* adding the group object (type = 'queue')
* making the modified contact/lead/queue email addresses to be in the same format as the user email addresses


<a href="https://githubsfdeploy.herokuapp.com">
  <img alt="Deploy to Salesforce"
       src="https://raw.githubusercontent.com/afawcett/githubsfdeploy/master/deploy.png">
</a>
