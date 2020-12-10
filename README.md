# sandbox-postcopy
*implements Salesforce's SandboxPostCopy and Batchable interfaces to modify email addresses on completion of a sandbox refresh*

In Salesforce's Spring '16 release, the <a href="https://docs.releasenotes.salesforce.com/en-us/spring16/release-notes/rn_deployment_sandbox_postcopy_script.htm">Run Script After Sandbox Creation and Refresh</a> feature was released. It allows developers to create an Apex class that implements the <a href="https://developer.salesforce.com/docs/atlas.en-us.apexcode.meta/apexcode/apex_interface_System_SandboxPostCopy.htm">SandboxPostCopy interface</a> and specify the class on the Sandbox Options screen (pictured in the screenshot at the top of this post).

One use for this is to modify email addresses that are included in records as part of refreshing a partial copy or full sandbox. Salesforce automatically <a href="https://help.salesforce.com/articleView?id=000333417&type=1">appends .invalid to sandbox user email addresses</a> but doesn't do so for other types of records (such as leads, contacts, or queues). Leaving these unmodified could end up in undesired email messages being sent to real prospects, customers, or employees.

I found some code published by <a href="https://github.com/bc-stephenoneal">Steve O'Neal</a> that used SandboxPostCopy in combination with the <a href="https://developer.salesforce.com/docs/atlas.en-us.apexcode.meta/apexcode/apex_interface_database_batchable.htm">Batchable interface</a> to modify sandbox email addresses in a way that can handle large numbers of records. I made a few modifications to Steve's code, including:

* changing the batch classes so the test class will work in production orgs (not just sandboxes)
* adding the group object (type = 'queue')
* making the modified contact/lead/queue email addresses to be in the same format as the user email addresses

<br>
<a href="https://githubsfdeploy.herokuapp.com">
  <img alt="Deploy to Salesforce"
       src="https://raw.githubusercontent.com/afawcett/githubsfdeploy/master/deploy.png">
</a>
