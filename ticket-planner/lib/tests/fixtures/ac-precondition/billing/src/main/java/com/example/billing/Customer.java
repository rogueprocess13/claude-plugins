package com.example.billing;

import jakarta.persistence.*;

@Entity
@Table(name = "customer_account")
public class Customer {

    @Id
    private Long id;

    private String name;
}
